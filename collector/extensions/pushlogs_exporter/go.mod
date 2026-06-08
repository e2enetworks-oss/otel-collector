module awakeninggit.e2enetworks.net/infra/e2e-otel-collector-app/extensions/pushlogs_exporter

go 1.26.0

require (
	go.opentelemetry.io/collector/component v1.54.0
	go.opentelemetry.io/collector/config/configretry v1.54.0
	go.opentelemetry.io/collector/exporter v0.148.0
	go.opentelemetry.io/collector/exporter/exporterhelper v0.148.0
	go.opentelemetry.io/collector/pdata v1.54.0
	go.uber.org/zap v1.27.1
	google.golang.org/grpc v1.79.2
	google.golang.org/protobuf v1.36.11
)
