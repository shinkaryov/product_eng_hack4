import hashlib
import secrets
from collections import defaultdict, deque
from datetime import UTC, datetime, timedelta
from threading import Lock
from time import monotonic
from typing import Annotated
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.orm import Session

from vault.config import get_settings
from vault.db import get_session

router = APIRouter(prefix="/v1")
DB = Annotated[Session, Depends(get_session)]
hasher = PasswordHasher()
dummy_hash = hasher.hash(secrets.token_hex(32))
attempts = defaultdict(deque)
lock = Lock()


def query(db, sql, **params):
    return db.execute(text(sql), params).mappings()


def required(row):
    if row is None:
        raise HTTPException(404, "Resource unavailable")
    return dict(row)


def digest(secret):
    return hashlib.sha256(secret.encode()).hexdigest()


def signing_key():
    key = get_settings().jwt_secret
    if len(key.encode()) < 32:
        raise HTTPException(503, "Configure JWT_SECRET with at least 32 bytes")
    return key


def limit(request, email):
    now = monotonic()
    with lock:
        for key in list(attempts):
            while attempts[key] and attempts[key][0] <= now - 60:
                attempts[key].popleft()
            if not attempts[key]:
                del attempts[key]
        keys = [
            (request.url.path, request.client.host if request.client else ""),
            ("email", email),
        ]
        if any(len(attempts[key]) >= 15 for key in keys):
            raise HTTPException(429, "Try again later")
        for key in keys:
            attempts[key].append(now)


class Login(BaseModel):
    email: str = Field(max_length=254, pattern=r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
    password: str = Field(min_length=1, max_length=256)


class Register(Login):
    password: str = Field(min_length=15, max_length=256)
    timezone: str = "UTC"


class Refresh(BaseModel):
    refresh_token: str = Field(max_length=256)


def tokens(db, session):
    refresh = secrets.token_urlsafe(48)
    query(
        db,
        """INSERT INTO vault.refresh_tokens(session_id, token_hash, expires_at)
                 VALUES (:sid,:hash,:expires)""",
        sid=session["id"],
        hash=digest(refresh),
        expires=session["expires_at"],
    )
    now = datetime.now(UTC)
    access = jwt.encode(
        {
            "sub": str(session["user_id"]),
            "sid": str(session["id"]),
            "iat": now,
            "exp": min(now + timedelta(minutes=15), session["expires_at"]),
            "iss": "vault",
            "aud": "vault-api",
        },
        signing_key(),
        algorithm="HS256",
    )
    db.commit()
    return {"access_token": access, "refresh_token": refresh, "token_type": "bearer"}


@router.post("/auth/register", status_code=201)
def register(body: Register, request: Request, db: DB):
    email = body.email.lower()
    limit(request, email)
    try:
        ZoneInfo(body.timezone)
    except (ValueError, ZoneInfoNotFoundError):
        raise HTTPException(422, "Unknown timezone")
    user = query(
        db,
        """INSERT INTO vault.users(email,password_hash,timezone) VALUES (:email,:password,:zone)
                        ON CONFLICT DO NOTHING RETURNING id,email,timezone""",
        email=email,
        password=hasher.hash(body.password),
        zone=body.timezone,
    ).first()
    if not user:
        raise HTTPException(409, "Email unavailable")
    db.commit()
    return dict(user)


@router.post("/auth/login")
def login(body: Login, request: Request, db: DB):
    email = body.email.lower()
    limit(request, email)
    user = query(
        db, "SELECT id,password_hash FROM vault.users WHERE email=:email", email=email
    ).first()
    try:
        hasher.verify(user["password_hash"] if user else dummy_hash, body.password)
    except VerifyMismatchError:
        raise HTTPException(401, "Invalid credentials")
    if not user:
        raise HTTPException(401, "Invalid credentials")
    session = query(
        db,
        """INSERT INTO vault.auth_sessions(user_id,expires_at)
                           VALUES (:uid,now()+interval '30 days') RETURNING *""",
        uid=user["id"],
    ).one()
    return tokens(db, session)


@router.post("/auth/refresh")
def refresh(body: Refresh, db: DB):
    row = query(
        db,
        """SELECT s.*, t.id AS token_id,t.consumed_at FROM vault.refresh_tokens t
                       JOIN vault.auth_sessions s ON s.id=t.session_id WHERE t.token_hash=:hash
                       AND s.revoked_at IS NULL AND least(t.expires_at,s.expires_at)>now()
                       FOR UPDATE OF s,t""",
        hash=digest(body.refresh_token),
    ).first()
    if not row:
        raise HTTPException(401, "Invalid session")
    if row["consumed_at"]:
        query(
            db,
            "UPDATE vault.auth_sessions SET revoked_at=now() WHERE id=:id",
            id=row["id"],
        )
        db.commit()
        raise HTTPException(401, "Invalid session")
    query(
        db,
        "UPDATE vault.refresh_tokens SET consumed_at=now() WHERE id=:id",
        id=row["token_id"],
    )
    return tokens(db, row)


def authenticated(
    db: DB,
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(HTTPBearer(auto_error=False))
    ],
):
    try:
        claims = jwt.decode(
            credentials.credentials if credentials else "",
            signing_key(),
            algorithms=["HS256"],
            issuer="vault",
            audience="vault-api",
            options={"require": ["sub", "sid", "exp", "iat"]},
        )
        sid, uid = UUID(claims["sid"]), UUID(claims["sub"])
    except (jwt.InvalidTokenError, ValueError, TypeError):
        raise HTTPException(401, "Invalid session")
    user = query(
        db,
        """SELECT u.id,u.email,u.timezone,s.id AS sid FROM vault.auth_sessions s
                        JOIN vault.users u ON u.id=s.user_id WHERE s.id=:sid AND u.id=:uid
                        AND s.revoked_at IS NULL AND s.expires_at>now()""",
        sid=sid,
        uid=uid,
    ).first()
    if not user:
        raise HTTPException(401, "Invalid session")
    return user


User = Annotated[dict, Depends(authenticated)]


@router.get("/users/me")
def me(user: User):
    return {key: user[key] for key in ("id", "email", "timezone")}


@router.post("/auth/logout", status_code=204)
def logout(db: DB, user: User):
    query(
        db,
        "UPDATE vault.auth_sessions SET revoked_at=now() WHERE id=:id",
        id=user["sid"],
    )
    db.commit()
