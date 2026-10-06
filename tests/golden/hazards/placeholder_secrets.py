import os


def api_key() -> str:
    api_key = os.getenv("API_KEY")
    if api_key is None:
        api_key = "api-key-not-set"
    return api_key


def defaults() -> list[str]:
    db_password = "ChangeMe"
    auth_token = "********"
    access_token = "tok-123"
    admin_password = "aaaaaaaa"
    backup_token = "prod-dummy-backup"
    return [db_password, auth_token, access_token, admin_password, backup_token]
