"""Focused checks for the temporary reader's actual format-conversion risks."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("pool_prototype", Path(__file__).with_name("pool-prototype.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class PoolPrototypeTests(unittest.TestCase):
    def test_real_sqlite_dates_identity_relationships_and_no_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "store"
            connection = sqlite3.connect(path)
            connection.executescript("""
                CREATE TABLE ZLONGTASK (Z_PK INTEGER,ZID BLOB,ZTITLE TEXT,ZNOTE TEXT,ZSTATUS TEXT,ZZONERAW TEXT,
                  ZCREATEDAT REAL,ZMODIFIEDAT REAL,ZDEADLINE REAL,ZDONEAT REAL,ZCADENCEMINUTESPERWEEK INTEGER,
                  ZTOTALMINUTES INTEGER,ZUNITMINUTES INTEGER,ZFAMILY TEXT,ZSPILLEDFROMDAY REAL);
                CREATE TABLE ZLONGTASKCHECKPOINT (ZID BLOB,ZTASK INTEGER,ZTITLE TEXT,ZORDER INTEGER,
                  ZESTIMATEDMINUTES INTEGER,ZCREATEDAT REAL,ZDONEAT REAL);
            """)
            identity, stage = uuid.uuid4(), uuid.uuid4()
            connection.execute("INSERT INTO ZLONGTASK VALUES(1,?,'愿望','保留正文','shelved','todo',0,60,NULL,NULL,NULL,NULL,NULL,NULL,NULL)", (identity.bytes,))
            connection.execute("INSERT INTO ZLONGTASKCHECKPOINT VALUES(?,1,'第一阶段',0,20,0,NULL)", (stage.bytes,))
            connection.commit()
            connection.close()
            original = path.read_bytes()
            payload, count, stages = reader.read_pool(path)
            value = json.loads(payload)["records"][0]["values"]
            self.assertEqual((count, stages), (1, 1))
            self.assertEqual(value["id"], str(identity).upper())
            self.assertEqual(value["createdAt"], 978307200000)
            self.assertEqual(value["modifiedAt"], 978307260000)
            self.assertEqual(value["status"], "shelved")
            self.assertEqual(value["checkpoints"][0]["id"], str(stage).upper())
            self.assertFalse(value["isInTrash"])
            self.assertEqual(path.read_bytes(), original)

    def test_deletion_matches_native_identity_semantics(self):
        identity = uuid.uuid4().bytes
        self.assertTrue(reader.deletion({"ZDELETIONID": identity})["isInTrash"])
        self.assertFalse(reader.deletion({"ZDELETIONID": identity, "ZRESTOREDDELETIONID": identity})["isInTrash"])
        self.assertFalse(reader.deletion({"ZDELETEDAT": 1})["isInTrash"])


if __name__ == "__main__":
    unittest.main()
