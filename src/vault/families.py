import secrets
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from vault.local_auth import DB, User, digest, query, required

router = APIRouter(prefix="/v1/families")


class Family(BaseModel):
    name: str = Field(min_length=1, max_length=150, pattern=r"\S")


class Invite(BaseModel):
    email: str


class Decision(BaseModel):
    secret: str
    decision: Literal["accept", "reject"]


class Leave(BaseModel):
    successor_user_id: UUID | None = None


def membership(db, user, family=None, owner=False):
    row = required(
        query(
            db,
            """SELECT m.*,f.name FROM vault.family_members m JOIN vault.families f
                                ON f.id=m.family_id WHERE m.user_id=:uid FOR UPDATE OF f,m""",
            uid=user["id"],
        ).first()
    )
    if family and family != row["family_id"]:
        raise HTTPException(404, "Family unavailable")
    if owner and row["role"] != "OWNER":
        raise HTTPException(403, "Family owner required")
    return row


@router.post("", status_code=201)
def create(body: Family, db: DB, user: User):
    row = query(
        db,
        "INSERT INTO vault.families(name) VALUES (:name) RETURNING *",
        name=body.name,
    ).one()
    query(
        db,
        "INSERT INTO vault.family_members(family_id,user_id,role) VALUES (:fid,:uid,'OWNER')",
        fid=row["id"],
        uid=user["id"],
    )
    db.commit()
    return dict(row)


@router.get("/me")
def current(db: DB, user: User):
    row = membership(db, user)
    return {"id": row["family_id"], "name": row["name"], "role": row["role"]}


@router.get("/{id}/members")
def members(id: UUID, db: DB, user: User):
    membership(db, user, id)
    return query(
        db,
        """SELECT m.user_id,m.role,m.joined_at,u.email FROM vault.family_members m
                        JOIN vault.users u ON u.id=m.user_id WHERE family_id=:id ORDER BY joined_at""",
        id=id,
    ).all()


@router.post("/invitations", status_code=201)
def invite(body: Invite, db: DB, user: User):
    family = membership(db, user, owner=True)["family_id"]
    target = required(
        query(
            db,
            "SELECT id FROM vault.users WHERE email=:email",
            email=body.email.lower(),
        ).first()
    )["id"]
    if query(
        db, "SELECT 1 FROM vault.family_members WHERE user_id=:target", target=target
    ).first():
        raise HTTPException(409, "Already a family member")
    if query(
        db,
        """SELECT 1 FROM vault.family_invitations WHERE family_id=:fid AND invitee_id=:target
                   AND state='PENDING' AND expires_at>now()""",
        fid=family,
        target=target,
    ).first():
        raise HTTPException(409, "Invitation pending")
    secret = secrets.token_urlsafe(32)
    row = query(
        db,
        """INSERT INTO vault.family_invitations(family_id,inviter_id,invitee_id,secret_hash,expires_at)
                      VALUES (:fid,:uid,:target,:hash,now()+interval '7 days') RETURNING id,expires_at""",
        fid=family,
        uid=user["id"],
        target=target,
        hash=digest(secret),
    ).one()
    db.commit()
    return dict(row, secret=secret)


@router.get("/invitations")
def invites(db: DB, user: User):
    fid = membership(db, user, owner=True)["family_id"]
    return query(
        db,
        "SELECT id,invitee_id,state,expires_at FROM vault.family_invitations WHERE family_id=:fid",
        fid=fid,
    ).all()


@router.post("/invitations/{id}/respond")
def respond(id: UUID, body: Decision, db: DB, user: User):
    row = required(
        query(
            db,
            """SELECT i.*,expires_at<=now() AS expired FROM vault.family_invitations i
                              JOIN vault.families f ON f.id=i.family_id WHERE i.id=:id AND invitee_id=:uid
                              AND secret_hash=:hash FOR UPDATE OF f,i""",
            id=id,
            uid=user["id"],
            hash=digest(body.secret),
        ).first()
    )
    if row["expired"]:
        raise HTTPException(410, "Expired invitation")
    if row["state"] != "PENDING":
        raise HTTPException(409, "Invitation already resolved")
    state = "REJECTED"
    if body.decision == "accept":
        query(
            db,
            "INSERT INTO vault.family_members(family_id,user_id,role) VALUES (:fid,:uid,'MEMBER')",
            fid=row["family_id"],
            uid=user["id"],
        )
        state = "ACCEPTED"
    query(
        db,
        "UPDATE vault.family_invitations SET state=:state WHERE id=:id",
        state=state,
        id=id,
    )
    db.commit()
    return {"id": id, "state": state}


def depart(db, fid, uid):
    query(
        db,
        """DELETE FROM vault.document_shares s USING vault.documents d
                WHERE s.document_id=d.id AND d.owner_id=:uid""",
        uid=uid,
    )
    query(
        db,
        "DELETE FROM vault.family_members WHERE family_id=:fid AND user_id=:uid",
        fid=fid,
        uid=uid,
    )


@router.delete("/{id}/members/{uid}", status_code=204)
def remove(id: UUID, uid: UUID, db: DB, user: User):
    membership(db, user, id, owner=True)
    if uid == user["id"]:
        raise HTTPException(409, "Use leave to transfer ownership")
    required(
        query(
            db,
            "SELECT id FROM vault.family_members WHERE family_id=:fid AND user_id=:uid",
            fid=id,
            uid=uid,
        ).first()
    )
    depart(db, id, uid)
    db.commit()


@router.post("/{id}/leave", status_code=204)
def leave(id: UUID, db: DB, user: User, body: Leave | None = None):
    member = membership(db, user, id)
    depart(db, id, user["id"])
    if member["role"] == "OWNER":
        if query(
            db, "SELECT 1 FROM vault.family_members WHERE family_id=:fid", fid=id
        ).first():
            if not query(
                db,
                "UPDATE vault.family_members SET role='OWNER' WHERE family_id=:fid AND user_id=:uid RETURNING id",
                fid=id,
                uid=body.successor_user_id if body else None,
            ).first():
                raise HTTPException(409, "Select a remaining member as successor")
        else:
            query(db, "DELETE FROM vault.families WHERE id=:fid", fid=id)
    db.commit()
