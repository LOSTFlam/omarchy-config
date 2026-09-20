"""The one exception every command raises, carrying the exit code to use."""

GENERAL = 1
USAGE = 2
NETWORK = 3
DUPLICATE = 4
UNKNOWN = 5
PIN_LIMIT = 6


class FreshTubeError(Exception):
    def __init__(self, message, code=GENERAL):
        super().__init__(message)
        self.code = code
