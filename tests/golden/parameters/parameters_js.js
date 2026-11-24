function total(prices, currency) {
    let sum = 0;
    for (const p of prices)
        sum += p;
    return sum;
}
function format(value, _locale) {
    const text = value.toFixed(2);
    return text;
}
class Cache {
    ttl;
    size;
    constructor(ttl, size, label) {
        this.ttl = ttl;
        this.size = size;
        this.start();
        this.warm();
    }
}
function run(logger, steps) {
    logger.info("start");
    logger.info(`steps: ${steps}`);
}
