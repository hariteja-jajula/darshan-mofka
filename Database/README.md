# Database

This is where MongoDB lives. FlowCept saves every Darshan event it receives into
MongoDB, and later `Client/export_jsonl.py` reads those events back out.

You need a `mongod` binary. You have two options:

**Use one you already have.** If MongoDB is available through a module, conda, or
on your `PATH`, just point the demo at it:

```bash
export MONGOD=/path/to/mongod
```

**Or download one here.** This grabs the official MongoDB tarball and unpacks it
into `Database/_mongo_env/` (no admin rights needed):

```bash
bash Database/get_mongod.sh
```

After that, `mongod` is at `Database/_mongo_env/bin/mongod` and the environment
scripts find it on their own.

The downloaded copy is not checked into git (it is a large binary). Re-run the
script on a fresh clone.
