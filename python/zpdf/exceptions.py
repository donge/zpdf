class ZpdfError(Exception):
    pass

class InvalidPdfError(ZpdfError):
    pass

class PageNotFoundError(ZpdfError, IndexError):
    pass

class ExtractionError(ZpdfError):
    pass
