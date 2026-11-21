from fastapi import FastAPI

app = FastAPI()


@app.get("/orders/{order_id}")
def get_order(order_id: str):
    return {"id": order_id}
