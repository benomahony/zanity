def describe(status: int) -> str:
    if status == 100:
        return "100"
    elif status == 101:
        return "101"
    elif status == 200:
        return "200"
    elif status == 201:
        return "201"
    elif status == 204:
        return "204"
    elif status == 301:
        return "301"
    elif status == 302:
        return "302"
    elif status == 304:
        return "304"
    elif status == 400:
        return "400"
    elif status == 401:
        return "401"
    elif status == 403:
        return "403"
    elif status == 404:
        return "404"
    elif status == 409:
        return "409"
    elif status == 429:
        return "429"
    elif status == 500:
        return "500"
    elif status == 503:
        return "503"
    return "unknown"
