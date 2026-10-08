class LogMessage {
    void record(Logger logger, String message) {
        logger.info(message);
    }

    void structured(Logger logger, String message) {
        logger.info("request message: {}", message);
    }

    void cleaned(Logger logger, String message) {
        String cleanedMessage = message.replace("\n", " ");
        logger.info(cleanedMessage);
    }
}
