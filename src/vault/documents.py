import hashlib
import json
from pathlib import Path
from typing import Annotated, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from vault.ai.policy import BLOCKED_TYPES
from vault.ai.schemas import DocType
from vault.config import get_settings
from vault.families import membership
from vault.local_auth import DB, User, query, required

router = APIRouter(prefix="/v1/documents")
# User-selectable categories = AI document types except blacklisted ones (vault.ai.policy).
Category = Literal[tuple(t.name for t in DocType if t not in BLOCKED_TYPES)]  # type: ignore[valid-type]
Status = Literal["PENDING", "PROCESSING", "COMPLETED", "FAILED"]
VIEWER_GRANT = """SELECT 1 FROM vault.document_shares s
    JOIN vault.family_members m ON m.id=s.membership_id
    JOIN vault.family_members o ON o.family_id=m.family_id WHERE m.user_id=:uid"""
ACCESS = """(d.owner_id=:uid OR (d.policy_outcome='ALLOWED' AND d.result_revision>0 AND EXISTS (
    """ + VIEWER_GRANT + " AND s.document_id=d.id AND o.user_id=d.owner_id)))"
SELECT_DOC = """SELECT d.*,j.status,j.error_code,j.started_at,j.finished_at,f.display_filename,f.media_type,f.size_bytes,
    j.status AS processing_stage,
    CASE WHEN d.policy_outcome='ALLOWED' THEN summary.summary END AS summary,
    CASE WHEN d.policy_outcome='ALLOWED' THEN summary.card END AS summary_card FROM vault.documents d
    JOIN vault.processing_jobs j ON j.document_id=d.id LEFT JOIN vault.document_files f ON f.document_id=d.id
    LEFT JOIN vault.document_summaries summary ON summary.document_id=d.id """


def document(db, user, id, *, owner=False, published=False, lock_share=False):
    row = required(
        query(
            db,
            SELECT_DOC + "WHERE d.id=:id AND " + ACCESS + " FOR UPDATE OF d",
            id=id,
            uid=user["id"],
        ).first()
    )
    if owner and row["owner_id"] != user["id"]:
        raise HTTPException(403, "Document owner required")
    if published and (row["policy_outcome"] != "ALLOWED" or not row["result_revision"]):
        raise HTTPException(409, "No allowed published result")
    if lock_share and row["owner_id"] != user["id"]:
        # Take a fresh snapshot after locking the document and serialize with membership revocation.
        required(query(
            db, VIEWER_GRANT + " AND s.document_id=:document_id AND o.user_id=:owner_id FOR SHARE OF s",
            document_id=id, owner_id=row["owner_id"], uid=user["id"],
        ).first())
    return row


def stored_path(key: UUID):
    return Path(get_settings().files_dir) / str(key)


class Metadata(BaseModel):
    title: str | None = Field(None, min_length=1, max_length=255, pattern=r"\S")
    category: Category | None = None
    subtype: str | None = Field(None, max_length=100)


class Corrections(BaseModel):
    expected_revision: int
    fields: dict


class Confirmation(BaseModel):
    expected_result_revision: int = Field(gt=0)
    expected_extraction_revision: int = Field(gt=0)


class Share(BaseModel):
    family_id: UUID


# ISO-BMFF brands written by iPhone cameras and other HEIF encoders (bytes 8..12, after "ftyp").
HEIC_BRANDS = {b"heic", b"heix", b"hevc", b"hevx"}
HEIF_BRANDS = {b"mif1", b"msf1", b"heim", b"heis"}
# Browsers often send HEIC photos without a specific media type.
HEIF_DECLARED = {"image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence", "application/octet-stream", "", None}


def validate_file(data, name, mime):
    """Check extension, declared media type and file signature. Returns the canonical media type."""
    suffix = Path(name).suffix.lower()
    if suffix in (".heic", ".heif"):
        brand = data[8:12] if data[4:8] == b"ftyp" else b""
        if mime in HEIF_DECLARED and brand in HEIC_BRANDS:
            return "image/heic"
        if mime in HEIF_DECLARED and brand in HEIF_BRANDS:
            return "image/heif"
        raise HTTPException(415, "File extension, media type or signature unsupported")
    types = {
        ".pdf": ("application/pdf", b"%PDF-"),
        ".png": ("image/png", b"\x89PNG\r\n\x1a\n"),
        ".jpg": ("image/jpeg", b"\xff\xd8\xff"),
        ".jpeg": ("image/jpeg", b"\xff\xd8\xff"),
    }
    kind = types.get(suffix)
    if not kind or kind[0] != mime or not data.startswith(kind[1]):
        raise HTTPException(415, "File extension, media type or signature unsupported")
    # No local parsing: Gemini reads the file. Size is capped by MAX_UPLOAD_MB in upload().
    if mime == "application/pdf" and b"/Encrypt" in data:
        raise HTTPException(422, "Password-protected PDFs are not supported")
    return mime


@router.post("", status_code=202)
def upload(
    db: DB,
    user: User,
    file: Annotated[UploadFile, File()],
    title: Annotated[str | None, Form(max_length=255)] = None,
    category: Annotated[Category | None, Form()] = None,
):
    limit = get_settings().max_upload_mb * 1024 * 1024
    data = file.file.read(limit + 1)
    if len(data) > limit:
        raise HTTPException(413, "File too large")
    name = Path((file.filename or "").replace(chr(92), "/")).name
    name = "".join(c for c in name if c.isprintable())[:255]
    media_type = validate_file(data, name, file.content_type)
    key = uuid4()
    path = stored_path(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as target:
        try:
            target.write(data)
            target.flush()
            id = query(
                db,
                """INSERT INTO vault.documents(owner_id,title,category)
                             VALUES (:uid,:title,:category) RETURNING id""",
                uid=user["id"],
                title=(title or name).strip() or name,
                category=category,
            ).one()["id"]
            query(
                db,
                """INSERT INTO vault.document_files VALUES (:id,:key,:name,:mime,:size,:hash)""",
                id=id,
                key=key,
                name=name,
                mime=media_type,
                size=len(data),
                hash=hashlib.sha256(data).hexdigest(),
            )
            query(
                db, "INSERT INTO vault.processing_jobs(document_id) VALUES (:id)", id=id
            )
            query(
                db,
                "INSERT INTO vault.document_events(document_id,event_name) VALUES (:id,'UPLOADED')",
                id=id,
            )
            result = document(db, user, id)
            db.commit()
        except Exception:
            path.unlink(missing_ok=True)
            raise
    return result


@router.get("")
def listing(
    db: DB,
    user: User,
    scope: Literal["owned", "shared", "all"] = "owned",
    category: Category | None = None,
    status: Status | None = None,
    cursor: UUID | None = None,
    limit: int = 50,
):
    conditions = [ACCESS]
    if scope != "all":
        conditions.append("d.owner_id=:uid" if scope == "owned" else "d.owner_id<>:uid")
    if category:
        conditions.append("d.category=:category")
    if status:
        conditions.append("j.status=:status")
    if cursor:
        conditions.append("d.id>:cursor")
    return query(
        db,
        SELECT_DOC
        + "WHERE "
        + " AND ".join(conditions)
        + " ORDER BY d.id LIMIT :limit",
        uid=user["id"],
        category=category,
        status=status,
        cursor=cursor,
        limit=max(1, min(100, limit)),
    ).all()


@router.get("/{id}")
def get(id: UUID, db: DB, user: User):
    return document(db, user, id)


@router.get("/{id}/file")
def download(id: UUID, db: DB, user: User):
    doc = document(db, user, id)
    row = query(
        db, "SELECT storage_key FROM vault.document_files WHERE document_id=:id", id=id
    ).first()
    if row is None:  # blocked documents keep no original
        raise HTTPException(404, "File not stored")
    path = stored_path(row["storage_key"])
    if not path.is_file():
        raise HTTPException(503, "File unavailable")
    return FileResponse(
        path,
        media_type=doc["media_type"],
        filename=doc["display_filename"],
        headers={"X-Content-Type-Options": "nosniff"},
    )


@router.patch("/{id}")
def edit(id: UUID, body: Metadata, db: DB, user: User):
    document(db, user, id, owner=True)
    query(
        db,
        """UPDATE vault.documents SET title=coalesce(:title,title),category=coalesce(:category,category),
                subtype=coalesce(:subtype,subtype),updated_at=now() WHERE id=:id""",
        id=id,
        **body.model_dump(),
    )
    result = document(db, user, id)
    db.commit()
    return result


@router.delete("/{id}", status_code=204)
def delete(id: UUID, db: DB, user: User):
    document(db, user, id, owner=True)
    query(
        db,
        "INSERT INTO vault.file_cleanup_jobs(storage_key) SELECT storage_key FROM vault.document_files WHERE document_id=:id",
        id=id,
    )
    query(db, "DELETE FROM vault.documents WHERE id=:id", id=id)
    db.commit()


@router.post("/{id}/reprocess", status_code=202)
def retry(id: UUID, db: DB, user: User):
    doc = document(db, user, id, owner=True)
    if doc["status"] in ("PROCESSING", "PENDING"):
        raise HTTPException(409, "Processing already queued")
    if doc["display_filename"] is None:
        raise HTTPException(409, "Original file is not stored")
    query(
        db,
        """UPDATE vault.processing_jobs SET status='PENDING',available_at=now(),attempts=0,
                error_code=NULL,started_at=NULL,finished_at=NULL WHERE document_id=:id""",
        id=id,
    )
    query(
        db,
        "UPDATE vault.documents SET review_status='UPLOADED',confirmed_at=NULL,updated_at=now() WHERE id=:id",
        id=id,
    )
    result = document(db, user, id)
    db.commit()
    return result


@router.post("/{id}/confirm")
def confirm(id: UUID, body: Confirmation, db: DB, user: User):
    doc = document(db, user, id, owner=True, published=True)
    if doc["status"] != "COMPLETED" or doc["review_status"] not in ("REVIEW_REQUIRED", "READY"):
        raise HTTPException(409, "Document is not ready for confirmation")
    revision = query(
        db, "SELECT revision FROM vault.document_extractions WHERE document_id=:id", id=id
    ).first()
    if (
        doc["result_revision"] != body.expected_result_revision
        or revision is None
        or revision["revision"] != body.expected_extraction_revision
    ):
        raise HTTPException(409, "Reviewed revision unavailable")
    if doc["review_status"] == "REVIEW_REQUIRED":
        updated = query(
            db,
            """UPDATE vault.documents SET review_status='READY',confirmed_at=now(),updated_at=now()
               WHERE id=:id RETURNING review_status,confirmed_at,updated_at""",
            id=id,
        ).one()
        doc.update(updated)
    db.commit()
    return doc


@router.get("/{id}/summary")
def summary(id: UUID, db: DB, user: User):
    doc = document(db, user, id, published=True)
    if doc["summary"] is None:
        raise HTTPException(404, "Summary unavailable")
    return {
        "document_id": id,
        "summary": doc["summary"],
        "card": doc["summary_card"],
        "revision": doc["result_revision"],
    }


@router.get("/{id}/extraction")
def extraction(id: UUID, db: DB, user: User):
    document(db, user, id, published=True)
    return required(
        query(
            db, "SELECT * FROM vault.document_extractions WHERE document_id=:id", id=id
        ).first()
    )


@router.patch("/{id}/extraction")
def correct(id: UUID, body: Corrections, db: DB, user: User):
    document(db, user, id, owner=True, published=True)
    row = query(
        db,
        """UPDATE vault.document_extractions SET overrides=overrides || cast(:fields AS jsonb),
                    revision=revision+1 WHERE document_id=:id AND revision=:revision RETURNING *""",
        id=id,
        revision=body.expected_revision,
        fields=json.dumps(body.fields),
    ).first()
    if not row:
        raise HTTPException(409, "Extraction revision unavailable")
    query(
        db,
        """UPDATE vault.documents SET review_status='REVIEW_REQUIRED',confirmed_at=NULL,updated_at=now()
           WHERE id=:id AND review_status='READY'""",
        id=id,
    )
    db.commit()
    return dict(row)


@router.get("/{id}/shares")
def shares(id: UUID, db: DB, user: User):
    document(db, user, id, owner=True)
    return query(
        db,
        """SELECT m.user_id,s.granted_at FROM vault.document_shares s JOIN vault.family_members m
                       ON m.id=s.membership_id WHERE s.document_id=:id""",
        id=id,
    ).all()


@router.post("/{id}/shares")
def share(id: UUID, body: Share, db: DB, user: User):
    document(db, user, id, owner=True, published=True)
    membership(db, user, body.family_id)
    query(
        db,
        """INSERT INTO vault.document_shares(document_id,membership_id)
                SELECT :id,id FROM vault.family_members WHERE family_id=:fid AND user_id<>:uid
                ON CONFLICT DO NOTHING""",
        id=id,
        fid=body.family_id,
        uid=user["id"],
    )
    result = shares(id, db, user)
    if not result:
        raise HTTPException(409, "No recipients")
    db.commit()
    return result


@router.delete("/{id}/shares", status_code=204)
def revoke(id: UUID, db: DB, user: User):
    document(db, user, id, owner=True)
    query(db, "DELETE FROM vault.document_shares WHERE document_id=:id", id=id)
    db.commit()
