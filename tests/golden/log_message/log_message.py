def record(logger, message):
    logger.info(message)


def structured(logger, message):
    logger.info("request message: %s", message)


def cleaned(logger, message):
    cleaned_message = message.replace("\n", " ")
    logger.info(cleaned_message)
