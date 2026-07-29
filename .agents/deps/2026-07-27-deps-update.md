# GitHub Actions dependency refresh

The `actions/checkout` workflow pin moves from 7.0.0 to 7.0.1. The repository
contract expectation is updated in the same change so it continues to verify
the exact reviewed commit rather than accepting a moving tag.

Validation for this change:

- `bash tests/test_install.sh`
- `python3 -m unittest discover -s tests -p 'test_*.py' -v`
- the pull request's deterministic GitHub Actions checks

The `actions/setup-python` workflow pin then moves from 6.3.0 to 7.0.0 in a
separate change. Its exact-SHA contract expectation moves with it and the
minimum supported Python remains 3.10.

Validation for the setup-python change:

- `bash tests/test_install.sh`
- `python3 -m unittest discover -s tests -p 'test_*.py' -v`
- the pull request's deterministic GitHub Actions checks
