def parse_header(header):
    if len(header) < 8:
        raise ValueError(f"E1042: hdr_ctx invalid ({len(header)})")
    return header[:8]
