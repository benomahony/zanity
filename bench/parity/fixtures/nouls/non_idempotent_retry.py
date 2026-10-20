def charge_with_retry(gateway, card, amount):
    for attempt in range(3):
        try:
            return gateway.charge(card, amount)
        except TimeoutError:
            continue
    raise TimeoutError(f"the gateway timed out 3 times charging {amount}")
