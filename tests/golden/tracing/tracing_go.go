package billing

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/honeycombio/beeline-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("billing")

type Job struct {
	ctx  context.Context
	span trace.Span
}

func Charge(ctx context.Context, id string) error {
	ctx, span := tracer.Start(ctx, "charge")
	return use(ctx, id)
}

func Refund(ctx context.Context, id string) error {
	ctx, span := tracer.Start(ctx, "refund")
	defer span.End()
	return use(ctx, id)
}

func Detached(ctx context.Context, id string) error {
	_, span := tracer.Start(ctx, "detached")
	defer span.End()
	return use(ctx, id)
}

func Concatenated(ctx context.Context, id string) error {
	ctx, span := tracer.Start(ctx, "charge "+id)
	defer span.End()
	return use(ctx, id)
}

func Formatted(ctx context.Context, id string) error {
	ctx, span := otel.Tracer("billing").Start(ctx, fmt.Sprintf("charge %s", id))
	defer span.End()
	return use(ctx, id)
}

func (j *Job) Begin(ctx context.Context) {
	j.ctx, j.span = tracer.Start(ctx, "job")
}

func Unsent(ctx context.Context, id string) error {
	ctx, span := beeline.StartSpan(ctx, "unsent")
	return use(ctx, id)
}

func Sent(ctx context.Context, id string) error {
	ctx, span := beeline.StartSpan(ctx, "sent")
	defer span.Send()
	return use(ctx, id)
}

func Command() error {
	cmd := exec.Command("true")
	err := cmd.Start()
	return err
}
