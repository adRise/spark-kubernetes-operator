# Apache Spark Kubernetes Operator - Tubi Guide

This guide documents how to use the Apache Spark Kubernetes Operator deployed in the `production-spark` namespace on the Scalamigo production cluster.

## Table of Contents

- [Cluster Status](#cluster-status)
- [Architecture Overview](#architecture-overview)
- [SparkApplication YAML Reference](#sparkapplication-yaml-reference)
- [Submitting Jobs](#submitting-jobs)
- [Managing Jobs](#managing-jobs)
- [Production Examples](#production-examples)
- [Troubleshooting](#troubleshooting)

---

## Cluster Status

### Current Deployment

| Component | Namespace | Status | Version |
|-----------|-----------|--------|---------|
| Spark Operator | `production-spark` | Running | 0.5.0 |
| Spark Connect Server | `production-spark` | RunningHealthy | 4.0.1 |
| Spark History Server | `production-spark` | RunningHealthy | 4.0.1 |

### Verify Operator Health

```bash
# Check operator pod
kubectl get pods -n production-spark -l app.kubernetes.io/name=spark-kubernetes-operator

# Check operator logs
kubectl logs -n production-spark deployment/spark-kubernetes-operator --tail=100

# List all SparkApplications
kubectl get sparkapplications -A

# List all SparkClusters
kubectl get sparkclusters -A
```

### CRDs Installed

```bash
# Verify CRDs
kubectl get crd | grep spark
# sparkapplications.spark.apache.org
# sparkclusters.spark.apache.org
```

---

## Architecture Overview

The Apache Spark Kubernetes Operator extends Kubernetes to manage Spark applications via the [Operator Pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/).

### Key Concepts

1. **SparkApplication** - A Custom Resource (CR) that defines a Spark job
2. **SparkCluster** - A CR for running persistent Spark clusters with master/worker nodes
3. **Operator** - Watches SparkApplication/SparkCluster resources and manages their lifecycle

### State Machine

SparkApplications go through these states:

```
Submitted → DriverRequested → DriverStarted → DriverReady → RunningHealthy → Succeeded/Failed
                                                                    ↓
                                                          ScheduledToRestart (if configured)
```

### Watched Namespaces

The operator is configured to watch:
- `production-spark`
- `default`

---

## SparkApplication YAML Reference

### Basic Structure

```yaml
apiVersion: spark.apache.org/v1
kind: SparkApplication
metadata:
  name: my-spark-job                    # Required: unique name
  namespace: production-spark           # Namespace to deploy to
  labels:                               # Optional: custom labels
    app: my-app
    environment: production
spec:
  # Entry Point (choose one)
  mainClass: "com.example.MyMainClass"  # For Java/Scala
  jars: "s3a://bucket/path/to/app.jar"  # JAR location
  # OR for Python:
  pyFiles: "s3a://bucket/path/to/app.py"
  
  # Driver arguments (optional)
  driverArgs: ["arg1", "arg2"]
  
  # Spark configuration
  sparkConf:
    spark.kubernetes.container.image: "apache/spark:4.0.1"
    spark.kubernetes.authenticate.driver.serviceAccountName: "spark"
    spark.kubernetes.namespace: "production-spark"
    # ... more spark configs
  
  # Runtime versions
  runtimeVersions:
    sparkVersion: "4.0.1"
    scalaVersion: "2.13"               # Optional
  
  # Application tolerations (lifecycle management)
  applicationTolerations:
    resourceRetainPolicy: OnFailure     # Never | OnFailure | Always
    restartConfig:
      restartPolicy: Never              # Never | OnFailure | Always | OnInfrastructureFailure
      maxRestartAttempts: 3
      restartBackoffMillis: 30000
    applicationTimeoutConfig:
      driverStartTimeoutMillis: 300000
      executorStartTimeoutMillis: 300000
  
  # Pod templates (optional, for advanced configuration)
  driverSpec:
    podTemplateSpec:
      # Kubernetes PodSpec
  executorSpec:
    podTemplateSpec:
      # Kubernetes PodSpec
```

### Complete Spec Reference

#### Entry Points

| Field | Type | Description |
|-------|------|-------------|
| `mainClass` | string | Main class for Java/Scala applications |
| `jars` | string | JAR file path (local://, s3a://, hdfs://) |
| `pyFiles` | string | Python file path for PySpark applications |
| `driverArgs` | []string | Arguments passed to the driver |

#### Application Tolerations

```yaml
applicationTolerations:
  # Resource retention after job ends
  resourceRetainPolicy: OnFailure  # Never | OnFailure | Always
  resourceRetainDurationMillis: 3600000  # Keep resources for 1 hour after failure
  ttlAfterStopMillis: -1  # -1 = keep forever, or milliseconds to auto-delete
  
  # Restart configuration
  restartConfig:
    restartPolicy: OnFailure  # Never | OnFailure | Always | OnInfrastructureFailure
    maxRestartAttempts: 3
    restartBackoffMillis: 30000  # Wait 30s between retries
    restartCounterResetMillis: 3600000  # Reset counter if running for 1 hour
  
  # Timeout configuration
  applicationTimeoutConfig:
    driverStartTimeoutMillis: 300000   # 5 min to start driver
    driverReadyTimeoutMillis: 300000   # 5 min for driver to be ready
    executorStartTimeoutMillis: 300000 # 5 min to acquire executors
    forceTerminationGracePeriodMillis: 300000
  
  # Instance configuration (executor count thresholds)
  instanceConfig:
    minExecutors: 1      # Minimum healthy executors
    initExecutors: 2     # Initial executors needed to start
    maxExecutors: 10     # Maximum executors
```

#### Driver/Executor Pod Templates

```yaml
driverSpec:
  podTemplateSpec:
    metadata:
      labels:
        app: my-spark-job
        component: driver
      annotations:
        iam.amazonaws.com/role: "arn:aws:iam::ACCOUNT:role/ROLE"
    spec:
      serviceAccountName: spark
      securityContext:
        runAsUser: 185
        runAsNonRoot: true
        fsGroup: 185
      containers:
        - name: spark-kubernetes-driver
          resources:
            requests:
              cpu: "4"
              memory: "8Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
      # volumes, nodeSelector, tolerations, etc.

executorSpec:
  podTemplateSpec:
    # Similar structure to driverSpec
```

#### Common SparkConf Settings

```yaml
sparkConf:
  # Container settings
  spark.kubernetes.container.image: "apache/spark:4.0.1"
  spark.kubernetes.container.image.pullPolicy: "IfNotPresent"
  spark.kubernetes.authenticate.driver.serviceAccountName: "spark"
  spark.kubernetes.namespace: "production-spark"
  
  # Driver settings
  spark.driver.cores: "4"
  spark.driver.memory: "8g"
  spark.driver.memoryOverhead: "2g"
  
  # Executor settings
  spark.executor.cores: "4"
  spark.executor.memory: "8g"
  
  # Dynamic allocation
  spark.dynamicAllocation.enabled: "true"
  spark.dynamicAllocation.shuffleTracking.enabled: "true"
  spark.dynamicAllocation.minExecutors: "1"
  spark.dynamicAllocation.maxExecutors: "10"
  spark.dynamicAllocation.initialExecutors: "2"
  
  # S3 access (AWS)
  spark.hadoop.fs.s3a.impl: "org.apache.hadoop.fs.s3a.S3AFileSystem"
  spark.hadoop.fs.s3a.fast.upload: "true"
  spark.kubernetes.driver.annotation.iam.amazonaws.com/role: "arn:aws:iam::ACCOUNT:role/ROLE"
  spark.kubernetes.executor.annotation.iam.amazonaws.com/role: "arn:aws:iam::ACCOUNT:role/ROLE"
  
  # Event logging (for History Server)
  spark.eventLog.enabled: "true"
  spark.eventLog.dir: "s3a://bucket/spark-history/"
  spark.eventLog.compress: "true"
  
  # External packages
  spark.jars.packages: "io.delta:delta-spark_2.13:4.0.0,org.apache.hadoop:hadoop-aws:3.4.0"
  spark.jars.ivy: "/tmp/ivy"
  
  # SQL settings
  spark.sql.adaptive.enabled: "true"
  spark.sql.shuffle.partitions: "200"
  
  # Labels for pods
  spark.kubernetes.driver.label.app: "my-app"
  spark.kubernetes.executor.label.app: "my-app"
```

---

## Submitting Jobs

### Submit a SparkApplication

```bash
# Apply the YAML file
kubectl apply -f my-spark-job.yaml -n production-spark

# Check status
kubectl get sparkapp my-spark-job -n production-spark

# Watch status changes
kubectl get sparkapp my-spark-job -n production-spark -w

# Get detailed status
kubectl describe sparkapp my-spark-job -n production-spark
```

### View Full Status YAML

```bash
kubectl get sparkapp my-spark-job -n production-spark -o yaml
```

The status section includes:
- `currentState.currentStateSummary` - Current state
- `stateTransitionHistory` - History of state changes
- `currentAttemptSummary` - Current attempt info
- `previousAttemptSummary` - Previous attempt (if restarted)

---

## Managing Jobs

### Delete a Job

```bash
kubectl delete sparkapp my-spark-job -n production-spark
```

### View Driver Logs

```bash
# Find the driver pod
kubectl get pods -n production-spark -l spark-role=driver

# View logs
kubectl logs <driver-pod-name> -n production-spark

# Follow logs
kubectl logs -f <driver-pod-name> -n production-spark
```

### Access Spark UI

```bash
# Port forward to driver pod (Spark UI on port 4040)
kubectl port-forward <driver-pod-name> 4040:4040 -n production-spark

# Then open http://localhost:4040
```

### Access History Server

The History Server is running as `spark-history-server` and listens on port 18080.

```bash
# Find the history server pod
kubectl get pods -n production-spark -l app=spark-history

# Port forward
kubectl port-forward spark-history-server-12-driver 18080:18080 -n production-spark

# Then open http://localhost:18080
```

---

## Production Examples

### Example 1: Basic Java/Scala Job

```yaml
apiVersion: spark.apache.org/v1
kind: SparkApplication
metadata:
  name: my-etl-job
  namespace: production-spark
  labels:
    app: my-etl
    environment: production
spec:
  mainClass: "com.tubi.etl.MyETLJob"
  jars: "s3a://tubi-spark-jars/my-etl-job-1.0.0.jar"
  driverArgs: ["--date", "2025-12-10"]
  sparkConf:
    spark.kubernetes.container.image: "apache/spark:4.0.1"
    spark.kubernetes.authenticate.driver.serviceAccountName: "spark"
    spark.kubernetes.namespace: "production-spark"
    spark.driver.cores: "4"
    spark.driver.memory: "8g"
    spark.executor.cores: "4"
    spark.executor.memory: "16g"
    spark.dynamicAllocation.enabled: "true"
    spark.dynamicAllocation.minExecutors: "2"
    spark.dynamicAllocation.maxExecutors: "20"
    spark.kubernetes.driver.annotation.iam.amazonaws.com/role: "arn:aws:iam::986748113845:role/flink_scalamigo_access-production"
    spark.kubernetes.executor.annotation.iam.amazonaws.com/role: "arn:aws:iam::986748113845:role/flink_scalamigo_access-production"
    spark.hadoop.fs.s3a.impl: "org.apache.hadoop.fs.s3a.S3AFileSystem"
    spark.eventLog.enabled: "true"
    spark.eventLog.dir: "s3a://tubi-scalamigo-datalake-production/spark-history/"
    spark.jars.packages: "io.delta:delta-spark_2.13:4.0.0,org.apache.hadoop:hadoop-aws:3.4.0"
    spark.jars.ivy: "/tmp/ivy"
  runtimeVersions:
    sparkVersion: "4.0.1"
    scalaVersion: "2.13"
  applicationTolerations:
    resourceRetainPolicy: OnFailure
    resourceRetainDurationMillis: 3600000
    restartConfig:
      restartPolicy: OnFailure
      maxRestartAttempts: 3
      restartBackoffMillis: 60000
  driverSpec:
    podTemplateSpec:
      spec:
        serviceAccountName: spark
        containers:
          - name: spark-kubernetes-driver
            resources:
              requests:
                cpu: "4"
                memory: "10Gi"
              limits:
                cpu: "4"
                memory: "10Gi"
```

### Example 2: PySpark Job

```yaml
apiVersion: spark.apache.org/v1
kind: SparkApplication
metadata:
  name: pyspark-analysis
  namespace: production-spark
spec:
  pyFiles: "s3a://tubi-spark-jars/analysis.py"
  sparkConf:
    spark.kubernetes.container.image: "apache/spark:4.0.1"
    spark.kubernetes.authenticate.driver.serviceAccountName: "spark"
    spark.kubernetes.namespace: "production-spark"
    spark.driver.memory: "4g"
    spark.executor.memory: "8g"
    spark.dynamicAllocation.enabled: "true"
    spark.dynamicAllocation.maxExecutors: "10"
    spark.kubernetes.driver.annotation.iam.amazonaws.com/role: "arn:aws:iam::986748113845:role/flink_scalamigo_access-production"
    spark.kubernetes.executor.annotation.iam.amazonaws.com/role: "arn:aws:iam::986748113845:role/flink_scalamigo_access-production"
    spark.hadoop.fs.s3a.impl: "org.apache.hadoop.fs.s3a.S3AFileSystem"
    spark.jars.packages: "org.apache.hadoop:hadoop-aws:3.4.0"
  runtimeVersions:
    sparkVersion: "4.0.1"
  applicationTolerations:
    resourceRetainPolicy: OnFailure
```

### Example 3: Long-Running Service (Spark Connect)

```yaml
apiVersion: spark.apache.org/v1
kind: SparkApplication
metadata:
  name: spark-connect-server
  namespace: production-spark
  labels:
    app: spark-connect
    environment: production
spec:
  mainClass: "org.apache.spark.sql.connect.service.SparkConnectServer"
  sparkConf:
    spark.connect.grpc.binding.host: "0.0.0.0"
    spark.connect.grpc.binding.port: "15002"
    spark.kubernetes.container.image: "apache/spark:4.0.1"
    spark.kubernetes.authenticate.driver.serviceAccountName: "spark"
    spark.driver.cores: "8"
    spark.driver.memory: "32g"
    spark.dynamicAllocation.enabled: "true"
    spark.dynamicAllocation.minExecutors: "1"
    spark.dynamicAllocation.maxExecutors: "60"
    # ... additional configs
  runtimeVersions:
    sparkVersion: "4.0.1"
  applicationTolerations:
    resourceRetainPolicy: OnFailure
    resourceRetainDurationMillis: 3600000
    restartConfig:
      restartPolicy: Always            # Always restart for long-running services
      maxRestartAttempts: 999999       # Effectively infinite restarts
      restartBackoffMillis: 30000
  driverSpec:
    podTemplateSpec:
      spec:
        serviceAccountName: spark
        containers:
          - name: spark-kubernetes-driver
            resources:
              requests:
                cpu: "8"
                memory: "20Gi"
              limits:
                cpu: "8"
                memory: "20Gi"
```

### Example 4: Job with PVC Storage

```yaml
apiVersion: spark.apache.org/v1
kind: SparkApplication
metadata:
  name: job-with-storage
  namespace: production-spark
spec:
  mainClass: "com.tubi.BigDataJob"
  jars: "s3a://tubi-spark-jars/big-data-job.jar"
  sparkConf:
    spark.kubernetes.container.image: "apache/spark:4.0.1"
    spark.kubernetes.authenticate.driver.serviceAccountName: "spark"
    # PVC for driver
    spark.kubernetes.driver.volumes.persistentVolumeClaim.spark-local-dir-1.mount.path: "/var/data/spark-local"
    spark.kubernetes.driver.volumes.persistentVolumeClaim.spark-local-dir-1.mount.readOnly: "false"
    spark.kubernetes.driver.volumes.persistentVolumeClaim.spark-local-dir-1.options.claimName: "OnDemand"
    spark.kubernetes.driver.volumes.persistentVolumeClaim.spark-local-dir-1.options.sizeLimit: "100Gi"
    spark.kubernetes.driver.volumes.persistentVolumeClaim.spark-local-dir-1.options.storageClass: "ebs-gp3-throughput"
    # PVC for executors
    spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.mount.path: "/var/data/spark-local"
    spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.mount.readOnly: "false"
    spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.claimName: "OnDemand"
    spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.sizeLimit: "400Gi"
    spark.kubernetes.executor.volumes.persistentVolumeClaim.spark-local-dir-1.options.storageClass: "ebs-gp3-throughput"
    spark.local.dir: "/var/data/spark-local"
    # ... other configs
  runtimeVersions:
    sparkVersion: "4.0.1"
  applicationTolerations:
    resourceRetainPolicy: OnFailure
```

---

## Troubleshooting

### Common Issues

#### 1. Job Stuck in DriverRequested

```bash
# Check events
kubectl describe sparkapp <name> -n production-spark

# Check for scheduling issues
kubectl get events -n production-spark --sort-by='.lastTimestamp'

# Check if service account exists
kubectl get serviceaccount spark -n production-spark
```

Possible causes:
- Insufficient cluster resources
- Service account not found
- Image pull errors

#### 2. Driver Fails to Start

```bash
# Check driver pod status
kubectl get pods -n production-spark -l spark-role=driver

# Check pod events
kubectl describe pod <driver-pod> -n production-spark

# Check init container logs
kubectl logs <driver-pod> -c <init-container-name> -n production-spark
```

#### 3. Executors Not Starting

```bash
# Check executor pods
kubectl get pods -n production-spark -l spark-role=executor

# Check driver logs for executor allocation
kubectl logs <driver-pod> -n production-spark | grep -i executor
```

#### 4. S3 Access Issues

Ensure IAM role annotation is set:
```yaml
spark.kubernetes.driver.annotation.iam.amazonaws.com/role: "arn:aws:iam::986748113845:role/flink_scalamigo_access-production"
spark.kubernetes.executor.annotation.iam.amazonaws.com/role: "arn:aws:iam::986748113845:role/flink_scalamigo_access-production"
```

#### 5. Out of Memory Errors

Increase memory settings:
```yaml
sparkConf:
  spark.driver.memory: "16g"
  spark.driver.memoryOverhead: "4g"
  spark.executor.memory: "32g"
  spark.executor.memoryOverhead: "4g"
```

### Useful Commands

```bash
# Get all Spark resources
kubectl get sparkapp,sparkcluster -n production-spark

# Get detailed job info
kubectl get sparkapp <name> -n production-spark -o yaml

# Watch all pods
kubectl get pods -n production-spark -w

# Check operator logs
kubectl logs deployment/spark-kubernetes-operator -n production-spark -f

# Delete stuck finalizers (use with caution)
kubectl patch sparkapp <name> -n production-spark -p '{"metadata":{"finalizers":null}}' --type=merge
```

### State Meanings

| State | Description |
|-------|-------------|
| `Submitted` | Application submitted to operator |
| `DriverRequested` | Driver pod requested from Kubernetes |
| `DriverStarted` | Driver pod is running |
| `DriverReady` | Driver is ready |
| `RunningHealthy` | Application running with healthy executors |
| `RunningWithBelowThresholdExecutors` | Running but below minimum executors |
| `Succeeded` | Application completed successfully |
| `Failed` | Application failed |
| `ScheduledToRestart` | Application scheduled for restart |
| `DriverStartTimedOut` | Driver failed to start in time |
| `ExecutorsStartTimedOut` | Failed to acquire minimum executors |

---

## References

- [Apache Spark K8s Operator GitHub](https://github.com/apache/spark-kubernetes-operator)
- [Operator Documentation](https://apache.github.io/spark-kubernetes-operator/)
- [Spark on Kubernetes Documentation](https://spark.apache.org/docs/latest/running-on-kubernetes.html)
- [Helm Chart](https://artifacthub.io/packages/helm/spark-kubernetes-operator/spark-kubernetes-operator/)

