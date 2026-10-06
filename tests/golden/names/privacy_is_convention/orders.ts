export function orderTotal() {
  return 1;
}

export const totalOrder = () => 2;

class Cart {
  _items() {
    return [];
  }

  items() {
    return this._items();
  }
}

class Basket {
  items() {
    return [];
  }
}
