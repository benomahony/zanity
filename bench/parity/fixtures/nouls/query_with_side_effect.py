def get_balance(account, db):
    account.last_checked = db.now()
    account.reads += 1
    db.save(account)
    return account.balance
