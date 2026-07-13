"""Compatibility test owner for the split AirVPN API provider suite."""

import unittest

from tests.airvpn_api_tests_cli import CliTests, InputBoundaryTests
from tests.airvpn_api_tests_generator import GeneratorBoundaryTests
from tests.airvpn_api_tests_profiles import (
    ProfileParsingTests,
    ProfileRenderingTests,
)
from tests.airvpn_api_tests_selection import (
    CandidateSelectionTests,
    CountryListingTests,
    EgressValidationTests,
    EndpointParsingTests,
    NumericValidationTests,
    StatusValidationTests,
)


_TEST_CLASSES = (
    CandidateSelectionTests,
    CliTests,
    CountryListingTests,
    EgressValidationTests,
    EndpointParsingTests,
    GeneratorBoundaryTests,
    InputBoundaryTests,
    NumericValidationTests,
    ProfileParsingTests,
    ProfileRenderingTests,
    StatusValidationTests,
)

for _test_class in _TEST_CLASSES:
    _test_class.__module__ = __name__


def load_tests(loader, _standard_tests, _pattern):
    """Load split classes once while retaining the original test IDs."""
    suite = unittest.TestSuite()
    for test_class in _TEST_CLASSES:
        suite.addTests(loader.loadTestsFromTestCase(test_class))
    return suite


if __name__ == "__main__":
    unittest.main()
