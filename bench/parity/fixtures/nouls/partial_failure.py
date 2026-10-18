def transfer(db, source, target, amount):
    db.execute("UPDATE accounts SET balance = balance - %s WHERE id = %s", (amount, source))
    db.execute("UPDATE accounts SET balance = balance + %s WHERE id = %s", (amount, target))
    db.execute("INSERT INTO ledger (source, target, amount) VALUES (%s, %s, %s)", (source, target, amount))
