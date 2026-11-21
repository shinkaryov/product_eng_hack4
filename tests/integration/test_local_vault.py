"""Run against the local Compose API from its container with this file on stdin."""

import json
import os
import time
import unittest
from datetime import date, timedelta
from uuid import uuid4

import struct
import zlib
import requests
from sqlalchemy import text

from vault.db import engine


def _png(width, height):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    rows = b"".join(b"\x00" + b"\xff" * width * 3 for _ in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


@unittest.skipUnless(
    __name__ == "__main__" or os.environ.get("VAULT_INTEGRATION") == "1",
    "Requires running Compose stack",
)
class LocalVaultTest(unittest.TestCase):
    def test_local_lifecycle(self):
        accounts = []
        family_id = None
        document_id = None

        def request(method, path, expected, token=None, **kwargs):
            headers = {"Authorization": f"Bearer {token}"} if token else {}
            response = requests.request(
                method,
                "http://localhost:8000/v1" + path,
                headers=headers,
                timeout=15,
                **kwargs,
            )
            self.assertEqual(response.status_code, expected, (path, response.text))
            return response

        def account():
            email = f"test-{uuid4().hex}@example.test"
            login = {"email": email, "password": uuid4().hex}
            user = request("POST", "/auth/register", 201, json=login).json()
            accounts.append(user["id"])
            return email, request("POST", "/auth/login", 200, json=login).json()

        try:
            _, alice_tokens = account()
            bob_email, bob_tokens = account()
            alice = alice_tokens["access_token"]
            bob = bob_tokens["access_token"]
            scan = _png(32, 32)  # tiny blank image; Gemini result is overwritten by fixtures below
            request(
                "POST",
                "/documents",
                415,
                alice,
                files={"file": ("bad.pdf", b"bad", "application/pdf")},
            )
            doc = request(
                "POST",
                "/documents",
                202,
                alice,
                files={"file": ("scan.png", scan, "image/png")},
            ).json()
            document_id = doc["id"]
            path = "/documents/" + document_id
            self.assertEqual(request("GET", path + "/file", 200, alice).content, scan)
            request("PATCH", path, 200, alice, json={"title": "Saved lease"})
            for suffix in ("", "/file", "/summary", "/extraction"):
                request("GET", path + suffix, 404, bob)
            self.assertEqual(
                request("GET", "/documents?scope=all", 200, bob).json(), []
            )
            # Wait for the worker (Gemini) to finish, then overwrite with fixed fixture data below.
            for _ in range(60):
                stage = request("GET", path, 200, alice).json()["processing_stage"]
                if stage in ("COMPLETED", "FAILED"):
                    break
                time.sleep(1)
            self.assertIn(stage, ("COMPLETED", "FAILED"))
            pages = [{"page": 1, "text": "Synthetic lease record", "method": "fixture"}]
            # Start from an unpublished state so sharing is refused until the fixture result below.
            with engine.begin() as db:
                db.execute(
                    text(
                        "UPDATE vault.documents SET policy_outcome=NULL,result_revision=0 WHERE id=:id"
                    ),
                    {"id": document_id},
                )
                for table in ("document_extractions", "document_summaries", "document_deadlines"):
                    db.execute(
                        text(f"DELETE FROM vault.{table} WHERE document_id=:id"),
                        {"id": document_id},
                    )
            family_id = request(
                "POST", "/families", 201, alice, json={"name": "Test family"}
            ).json()["id"]
            invite = request(
                "POST", "/families/invitations", 201, alice, json={"email": bob_email}
            ).json()
            request(
                "POST",
                f"/families/invitations/{invite['id']}/respond",
                200,
                bob,
                json={"secret": invite["secret"], "decision": "accept"},
            )
            self.assertEqual(
                len(request("GET", f"/families/{family_id}/members", 200, bob).json()),
                2,
            )
            request("GET", path, 404, bob)
            request("POST", path + "/shares", 409, alice, json={"family_id": family_id})
            # Simulate a previously published result. This is database fixture data only.
            with engine.begin() as db:
                params = {"id": document_id, "pages": json.dumps(pages)}
                db.execute(
                    text(
                        "UPDATE vault.documents SET policy_outcome='ALLOWED',result_revision=1 WHERE id=:id"
                    ),
                    params,
                )
                db.execute(
                    text("""INSERT INTO vault.document_extractions(document_id,revision,pages,facts,model_id,schema_version)
                                   VALUES (:id,1,cast(:pages AS jsonb),'{}','fixture',1)
                                   ON CONFLICT (document_id) DO UPDATE SET revision=1,pages=EXCLUDED.pages,
                                   facts='{}',overrides='{}',model_id='fixture'"""),
                    params,
                )
                db.execute(
                    text("""INSERT INTO vault.document_summaries(document_id,revision,summary,card,model_id,prompt_version)
                                   VALUES (:id,1,'Saved lease','{}','fixture','fixture')
                                   ON CONFLICT (document_id) DO UPDATE SET revision=1,summary='Saved lease'"""),
                    params,
                )
            request(
                "PATCH",
                path + "/extraction",
                200,
                alice,
                json={"expected_revision": 1, "fields": {"provider": "Test provider"}},
            )
            request("POST", path + "/shares", 200, alice, json={"family_id": family_id})
            self.assertEqual(
                request("GET", path + "/summary", 200, bob).json()["summary"],
                "Saved lease",
            )
            request("GET", path + "/extraction", 200, bob)
            request("DELETE", path, 403, bob)
            session = request("POST", path + "/chat", 201, bob, json={}).json()["id"]
            request("GET", "/chat/" + session, 200, bob)
            request("GET", "/chat/" + session, 404, alice)
            deadline = request(
                "POST",
                path + "/deadlines",
                201,
                alice,
                json={"type": "OTHER", "date": str(date.today() + timedelta(days=12))},
            ).json()
            reminders = request("GET", "/reminders", 200, alice).json()
            self.assertEqual(len(reminders), 2)
            self.assertEqual(request("GET", "/reminders", 200, bob).json(), [])
            request("POST", "/reminders/" + reminders[0]["id"] + "/dismiss", 200, alice)
            request(
                "PATCH",
                path + "/deadlines/" + deadline["id"],
                200,
                alice,
                json={"state": "REJECTED"},
            )
            self.assertEqual(request("GET", "/reminders", 200, alice).json(), [])
            request("DELETE", path + "/shares", 204, alice)
            request("GET", "/chat/" + session, 404, bob)
            request("GET", path + "/summary", 404, bob)
            request("POST", path + "/shares", 200, alice, json={"family_id": family_id})
            request("POST", f"/families/{family_id}/leave", 204, bob, json={})
            request("GET", path + "/file", 404, bob)
            request("DELETE", path, 204, alice)
            request("GET", path, 404, alice)
            refreshed = request(
                "POST",
                "/auth/refresh",
                200,
                json={"refresh_token": bob_tokens["refresh_token"]},
            ).json()
            request(
                "POST",
                "/auth/refresh",
                401,
                json={"refresh_token": bob_tokens["refresh_token"]},
            )
            request("GET", "/users/me", 401, refreshed["access_token"])
            request("POST", "/auth/logout", 204, alice)
            request("GET", "/users/me", 401, alice)
        finally:
            with engine.begin() as db:
                if document_id:
                    db.execute(
                        text("""INSERT INTO vault.file_cleanup_jobs(storage_key) SELECT storage_key
                                       FROM vault.document_files WHERE document_id=:id ON CONFLICT DO NOTHING"""),
                        {"id": document_id},
                    )
                    db.execute(
                        text("DELETE FROM vault.documents WHERE id=:id"),
                        {"id": document_id},
                    )
                if family_id:
                    db.execute(
                        text("DELETE FROM vault.families WHERE id=:id"),
                        {"id": family_id},
                    )
                for uid in accounts:
                    db.execute(
                        text("DELETE FROM vault.users WHERE id=:uid"), {"uid": uid}
                    )


if __name__ == "__main__":
    unittest.main()
