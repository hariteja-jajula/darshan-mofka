# workloads/python-ml

A small machine-learning style workload used to exercise the connector with a
Python program instead of a C program.

`train.py` writes a dataset to disk, reads it back over a couple of epochs, and
saves a checkpoint. The model itself is not the point — the file reads and writes
are, because that is what Darshan records and streams to Mofka.

It uses PyTorch if it is installed and falls back to NumPy-free plain Python if it
is not, so it runs even on Python builds without a PyTorch wheel. The file I/O is
identical either way.

## Run it through job.sh

```bash
bash job.sh python-ml
```

## Run it by hand

The dataset size is adjustable with a few environment variables:

```bash
ML_FILES=6 ML_ROWS=512 ML_COLS=16 ML_EPOCHS=2 \
  python workloads/python-ml/train.py /tmp/mofka-ml
```

To run it under the connector yourself, set `LD_PRELOAD` to the Darshan library
and the `DARSHAN_MOFKA_*` variables, the same way the C smoke workload does (see
[`../c/README.md`](../c/README.md)).
