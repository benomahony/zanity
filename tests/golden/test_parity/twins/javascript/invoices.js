function invoiceTotal(items, rate) {
  let total = 0;
  for (const item of items) {
    if (item > 10) {
      total += item * rate;
    } else {
      total += item;
    }
  }
  return total;
}

module.exports = { invoiceTotal };
