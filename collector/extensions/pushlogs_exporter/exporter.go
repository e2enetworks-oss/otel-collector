package pushlogs_exporter

import (
	"context"
	"fmt"
	"time"

	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/exporter"
	"go.opentelemetry.io/collector/exporter/exporterhelper"
	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/plog"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"

	ingestpb "awakeninggit.e2enetworks.net/infra/e2e-otel-collector-app/extensions/pushlogs_exporter/proto"
)

type pushLogsExporter struct {
	cfg    *Config
	logger *zap.Logger
	conn   *grpc.ClientConn
	client ingestpb.LogIngestServiceClient
}

func newPushLogsExporter(ctx context.Context, set exporter.Settings, cfg *Config) (exporter.Logs, error) {
	exp := &pushLogsExporter{
		cfg:    cfg,
		logger: set.Logger,
	}
	return exporterhelper.NewLogs(
		ctx,
		set,
		cfg,
		exp.pushLogs,
		exporterhelper.WithStart(exp.start),
		exporterhelper.WithShutdown(exp.shutdown),
		exporterhelper.WithTimeout(exporterhelper.TimeoutConfig{Timeout: cfg.Timeout}),
		exporterhelper.WithRetry(cfg.RetryConfig),
	)
}

func (e *pushLogsExporter) start(_ context.Context, _ component.Host) error {
	conn, err := grpc.NewClient(
		e.cfg.Endpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return fmt.Errorf("pushlogs_exporter: dial %s: %w", e.cfg.Endpoint, err)
	}
	e.conn = conn
	e.client = ingestpb.NewLogIngestServiceClient(conn)
	e.logger.Info("pushlogs_exporter: connected to observability-api",
		zap.String("endpoint", e.cfg.Endpoint),
		zap.String("log_group", e.cfg.LogGroup),
	)
	return nil
}

func (e *pushLogsExporter) shutdown(_ context.Context) error {
	if e.conn != nil {
		return e.conn.Close()
	}
	return nil
}

// pushLogs converts plog.Logs → PushLogsRequest batches grouped by log_stream,
// then calls PushLogs on observability-api with the Bearer ingestion token.
func (e *pushLogsExporter) pushLogs(ctx context.Context, ld plog.Logs) error {
	// Group events by log_stream.
	streamBatches := make(map[string][]*ingestpb.LogEvent)

	rls := ld.ResourceLogs()
	for i := 0; i < rls.Len(); i++ {
		rl := rls.At(i)
		resourceAttrs := rl.Resource().Attributes()

		sls := rl.ScopeLogs()
		for j := 0; j < sls.Len(); j++ {
			lrs := sls.At(j).LogRecords()
			for k := 0; k < lrs.Len(); k++ {
				lr := lrs.At(k)

				// Derive log_stream: check log attrs first, then resource attrs, then default.
				logStream := "default"
				if v, ok := lr.Attributes().Get(e.cfg.LogStreamAttribute); ok {
					logStream = v.AsString()
				} else if v, ok := resourceAttrs.Get(e.cfg.LogStreamAttribute); ok {
					logStream = v.AsString()
				}

				streamBatches[logStream] = append(streamBatches[logStream], e.toLogEvent(lr))
			}
		}
	}

	if len(streamBatches) == 0 {
		return nil
	}

	// Inject Bearer token into every gRPC call.
	md := metadata.Pairs("authorization", "Bearer "+e.cfg.Token)
	ctx = metadata.NewOutgoingContext(ctx, md)

	for logStream, events := range streamBatches {
		req := &ingestpb.PushLogsRequest{
			LogGroup:  e.cfg.LogGroup,
			LogStream: logStream,
			LogEvents: events,
		}
		resp, err := e.client.PushLogs(ctx, req)
		if err != nil {
			return fmt.Errorf("pushlogs_exporter: PushLogs stream=%q: %w", logStream, err)
		}
		if resp.Rejected > 0 {
			e.logger.Warn("pushlogs_exporter: events rejected by observability-api",
				zap.String("log_stream", logStream),
				zap.Uint32("accepted", resp.Accepted),
				zap.Uint32("rejected", resp.Rejected),
			)
		}
	}
	return nil
}

// toLogEvent converts a plog.LogRecord to the proto LogEvent.
func (e *pushLogsExporter) toLogEvent(lr plog.LogRecord) *ingestpb.LogEvent {
	// Timestamp in milliseconds. Prefer record timestamp over observed.
	ts := lr.Timestamp()
	if ts == 0 {
		ts = lr.ObservedTimestamp()
	}
	tsMs := int64(ts) / int64(time.Millisecond)
	if tsMs <= 0 {
		tsMs = time.Now().UnixMilli()
	}

	// Collect log attributes as string metadata.
	meta := make(map[string]string, lr.Attributes().Len())
	lr.Attributes().Range(func(k string, v pcommon.Value) bool {
		meta[k] = v.AsString()
		return true
	})

	event := &ingestpb.LogEvent{
		Timestamp: tsMs,
		Message:   lr.Body().AsString(),
		Level:     severityToLevel(lr.SeverityNumber()),
	}
	if len(meta) > 0 {
		event.Metadata = meta
	}

	// Propagate trace context when present.
	traceID := lr.TraceID()
	spanID := lr.SpanID()
	if !traceID.IsEmpty() && !spanID.IsEmpty() {
		event.TraceContext = &ingestpb.TraceContext{
			TraceId:    fmt.Sprintf("%x", traceID[:]),
			SpanId:     fmt.Sprintf("%x", spanID[:]),
			TraceFlags: uint32(lr.Flags()),
		}
	}

	return event
}

func severityToLevel(sn plog.SeverityNumber) ingestpb.LogLevel {
	switch {
	case sn >= plog.SeverityNumberFatal:
		return ingestpb.LogLevel_LOG_LEVEL_FATAL
	case sn >= plog.SeverityNumberError:
		return ingestpb.LogLevel_LOG_LEVEL_ERROR
	case sn >= plog.SeverityNumberWarn:
		return ingestpb.LogLevel_LOG_LEVEL_WARN
	case sn >= plog.SeverityNumberInfo:
		return ingestpb.LogLevel_LOG_LEVEL_INFO
	case sn >= plog.SeverityNumberDebug:
		return ingestpb.LogLevel_LOG_LEVEL_DEBUG
	default:
		return ingestpb.LogLevel_LOG_LEVEL_UNSPECIFIED
	}
}
