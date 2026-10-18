def place_order(db, cart, customer):
    validate(cart)
    total = 0
    for line in cart.splitlines():
        name, quantity, price = line.split(",")
        total += int(quantity) * float(price)
    db.execute("INSERT INTO orders (customer, total) VALUES ('" + customer + "', " + str(total) + ")")
    send_confirmation(customer)
