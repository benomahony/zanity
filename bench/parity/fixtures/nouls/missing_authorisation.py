def delete_account(request, db, account_id):
    account = db.accounts.get(account_id)
    db.accounts.delete(account)
    return {"deleted": account_id}
