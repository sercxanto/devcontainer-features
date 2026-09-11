Read and follow @CONTRIBUTING.md — it is written for you as much as for humans.

The rest of this file is only what humans would not need telling:

- Claims of verification come with evidence. "Tests pass" means you ran
  `run-local.sh` and `run-harness.sh` in this session and can show the
  summary lines. If you could not run them, say so instead.
- Do not publish, push, tag, or create remote repositories. Those are the
  maintainer's actions; propose them, including the `version` bump.
- Do not remove or rename the Docker volume `shared-agent-config`. It may be
  the maintainer's live config. Test volumes are named per run and cleaned up
  by the test scripts.
- The feature is used from `dev.containers.defaultFeatures`, so it runs inside
  containers of repositories nobody has reviewed. Treat every change to
  `install.sh` and `setup.sh` as running with that exposure.
