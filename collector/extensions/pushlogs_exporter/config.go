package pushlogs_exporter

import (
	"errors"
	"time"

	"go.opentelemetry.io/collector/config/configretry"
)

// Config holds the pushlogs exporter configuration.
type Config struct {
	// Endpoint is the observability-api gRPC address (plaintext).
	// Cross-cluster (VPC): e.g. "172.16.230.168:31880"
	// Same-cluster:        e.g. "observability-api.logging.svc.cluster.local:8080"
	Endpoint string `mapstructure:"endpoint"`

	// LogGroup is the target log group (must already exist via CreateLogGroup).
	// e.g. "logs.dev.cluster3.infra"
	LogGroup string `mapstructure:"log_group"`

	// LogStreamAttribute is the log or resource attribute whose value becomes
	// the log_stream sent to observability-api. Defaults to "k8s.pod.name".
	// Falls back to "default" when the attribute is absent.
	LogStreamAttribute string `mapstructure:"log_stream_attribute"`

	// Token is the Bearer ingestion token for this log group.
	// Inject from env: token: "${env:CLUSTER_INGESTION_TOKEN}"
	Token string `mapstructure:"token"`

	// Timeout per PushLogs gRPC call.
	Timeout time.Duration `mapstructure:"timeout"`

	// RetryConfig controls exponential back-off on transient errors.
	RetryConfig configretry.BackOffConfig `mapstructure:"retry_on_failure"`
}

func (c *Config) Validate() error {
	if c.Endpoint == "" {
		return errors.New("pushlogs_exporter: endpoint is required")
	}
	if c.LogGroup == "" {
		return errors.New("pushlogs_exporter: log_group is required")
	}
	if c.Token == "" {
		return errors.New("pushlogs_exporter: token is required")
	}
	return nil
}

func defaultConfig() *Config {
	return &Config{
		LogStreamAttribute: "k8s.pod.name",
		Timeout:            10 * time.Second,
		RetryConfig:        configretry.NewDefaultBackOffConfig(),
	}
}
