from fastapi import FastAPI

from telemetry import tracer

app = FastAPI()


@app.get("/orders/{order_id}")
def get_order(order_id: str):
    return {"id": order_id}


@app.post("/orders")
def create_order(order: dict):
    with tracer.start_as_current_span("create_order"):
        return order


@app.delete("/orders/{order_id}")
@tracer.start_as_current_span("delete_order")
def delete_order(order_id: str):
    return {"deleted": order_id}


def total(order: dict):
    return order.get("total")
