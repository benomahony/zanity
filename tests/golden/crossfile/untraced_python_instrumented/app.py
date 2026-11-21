from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

tracer = trace.get_tracer(__name__)
app = FastAPI()
FastAPIInstrumentor.instrument_app(app)


@app.get("/orders/{order_id}")
def get_order(order_id: str):
    return {"id": order_id}
