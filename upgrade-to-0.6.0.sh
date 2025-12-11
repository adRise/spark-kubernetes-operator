#!/bin/bash
#
# Spark Kubernetes Operator Upgrade Script
# Upgrades from 0.5.0 to 0.6.0
#
# Prerequisites:
# - kubectl configured with scalamigo-v2-production context
# - Helm 3.x installed
# 
# Usage: ./upgrade-to-0.6.0.sh [--dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHART_DIR="${SCRIPT_DIR}/build-tools/helm/spark-kubernetes-operator"
VALUES_FILE="${SCRIPT_DIR}/tubi-production-values.yaml"
NAMESPACE="production-spark"
RELEASE_NAME="spark-operator"
BACKUP_DIR="${SCRIPT_DIR}/backup-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

DRY_RUN=""
DRY_RUN_SERVER=""
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN="--dry-run=client"
    DRY_RUN_SERVER="--dry-run=server"
    echo_warn "Running in DRY-RUN mode. No changes will be applied."
fi

# Check prerequisites
check_prerequisites() {
    echo_info "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        echo_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        echo_error "helm not found. Please install helm 3.x first."
        echo_info "Install with: brew install helm"
        exit 1
    fi
    
    # Check context
    CURRENT_CONTEXT=$(kubectl config current-context)
    if [[ "$CURRENT_CONTEXT" != "scalamigo-v2-production" ]]; then
        echo_error "Wrong kubectl context. Expected: scalamigo-v2-production, Got: $CURRENT_CONTEXT"
        echo_info "Switch context with: kubectl config use-context scalamigo-v2-production"
        exit 1
    fi
    
    # Check namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo_error "Namespace $NAMESPACE does not exist!"
        exit 1
    fi
    
    # Check values file exists
    if [[ ! -f "$VALUES_FILE" ]]; then
        echo_error "Values file not found: $VALUES_FILE"
        exit 1
    fi
    
    echo_info "Prerequisites check passed."
}

# Backup current state
backup_current_state() {
    echo_info "Backing up current state to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup deployment
    kubectl get deployment spark-kubernetes-operator -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/deployment.yaml" 2>/dev/null || true
    
    # Backup configmap
    kubectl get configmap spark-kubernetes-operator-configuration -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/configmap.yaml" 2>/dev/null || true
    
    # Backup CRDs
    kubectl get crd sparkapplications.spark.apache.org -o yaml > "$BACKUP_DIR/crd-sparkapplications.yaml" 2>/dev/null || true
    kubectl get crd sparkclusters.spark.apache.org -o yaml > "$BACKUP_DIR/crd-sparkclusters.yaml" 2>/dev/null || true
    
    # Backup RBAC
    kubectl get clusterrole spark-operator-clusterrole -o yaml > "$BACKUP_DIR/clusterrole-operator.yaml" 2>/dev/null || true
    kubectl get clusterrole spark-workload-clusterrole -o yaml > "$BACKUP_DIR/clusterrole-workload.yaml" 2>/dev/null || true
    kubectl get clusterrolebinding spark-operator-clusterrolebinding -o yaml > "$BACKUP_DIR/clusterrolebinding.yaml" 2>/dev/null || true
    
    # Backup service accounts
    kubectl get serviceaccount spark -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/sa-spark.yaml" 2>/dev/null || true
    kubectl get serviceaccount spark-operator -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/sa-spark-operator.yaml" 2>/dev/null || true
    
    # Backup running SparkApplications
    kubectl get sparkapplications -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/sparkapplications.yaml" 2>/dev/null || true
    
    echo_info "Backup completed at $BACKUP_DIR"
}

# Display current state
show_current_state() {
    echo_info "Current Spark Operator State:"
    echo ""
    
    echo "=== Deployment ==="
    kubectl get deployment spark-kubernetes-operator -n "$NAMESPACE" -o wide 2>/dev/null || echo "Not found"
    echo ""
    
    echo "=== Current Version ==="
    kubectl get deployment spark-kubernetes-operator -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "Not found"
    echo ""
    echo ""
    
    echo "=== Running SparkApplications ==="
    kubectl get sparkapplications -n "$NAMESPACE" 2>/dev/null || echo "None"
    echo ""
    
    echo "=== CRD Versions ==="
    kubectl get crd sparkapplications.spark.apache.org -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null
    echo " (sparkapplications)"
    kubectl get crd sparkclusters.spark.apache.org -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null
    echo " (sparkclusters)"
    echo ""
}

# Update CRDs
update_crds() {
    echo_info "Updating CRDs..."
    
    # Apply new CRDs (server-side apply for merge)
    if [[ -n "$DRY_RUN_SERVER" ]]; then
        kubectl apply -f "${HELM_CHART_DIR}/crds/sparkapplications.spark.apache.org-v1.yaml" $DRY_RUN_SERVER --server-side --force-conflicts
        kubectl apply -f "${HELM_CHART_DIR}/crds/sparkclusters.spark.apache.org-v1.yaml" $DRY_RUN_SERVER --server-side --force-conflicts
    else
        kubectl apply -f "${HELM_CHART_DIR}/crds/sparkapplications.spark.apache.org-v1.yaml" --server-side --force-conflicts
        kubectl apply -f "${HELM_CHART_DIR}/crds/sparkclusters.spark.apache.org-v1.yaml" --server-side --force-conflicts
    fi
    
    echo_info "CRDs updated successfully."
}

# Upgrade operator with Helm
upgrade_operator() {
    echo_info "Upgrading Spark Operator to 0.6.0..."
    
    # Add/update helm repo
    helm repo add spark https://apache.github.io/spark-kubernetes-operator 2>/dev/null || true
    helm repo update
    
    # Show what will change (diff)
    echo_info "Showing upgrade diff..."
    helm diff upgrade "$RELEASE_NAME" "$HELM_CHART_DIR" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE" \
        2>/dev/null || echo_warn "helm-diff plugin not installed, skipping diff"
    
    # Perform upgrade
    if [[ -n "$DRY_RUN" ]]; then
        echo_info "DRY-RUN: Would execute helm upgrade"
        helm upgrade "$RELEASE_NAME" "$HELM_CHART_DIR" \
            --namespace "$NAMESPACE" \
            --values "$VALUES_FILE" \
            --dry-run
    else
        echo ""
        read -p "Proceed with upgrade? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            helm upgrade "$RELEASE_NAME" "$HELM_CHART_DIR" \
                --namespace "$NAMESPACE" \
                --values "$VALUES_FILE" \
                --wait \
                --timeout 10m
            
            echo_info "Helm upgrade completed."
        else
            echo_warn "Upgrade cancelled."
            exit 0
        fi
    fi
}

# Verify upgrade
verify_upgrade() {
    echo_info "Verifying upgrade..."
    
    echo ""
    echo "=== New Deployment ==="
    kubectl get deployment spark-kubernetes-operator -n "$NAMESPACE" -o wide
    echo ""
    
    echo "=== New Image Version ==="
    kubectl get deployment spark-kubernetes-operator -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}'
    echo ""
    echo ""
    
    echo "=== Pod Status ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=spark-kubernetes-operator
    echo ""
    
    echo "=== SparkApplications Status ==="
    kubectl get sparkapplications -n "$NAMESPACE"
    echo ""
    
    # Wait for pod to be ready
    echo_info "Waiting for operator pod to be ready..."
    kubectl rollout status deployment/spark-kubernetes-operator -n "$NAMESPACE" --timeout=5m || true
    
    # Check logs for errors
    echo ""
    echo "=== Recent Operator Logs ==="
    kubectl logs deployment/spark-kubernetes-operator -n "$NAMESPACE" --tail=20 2>/dev/null || echo "Unable to fetch logs"
    
    echo ""
    echo_info "Upgrade verification complete."
}

# Main execution
main() {
    echo "=================================================="
    echo " Spark Kubernetes Operator Upgrade: 0.5.0 -> 0.6.0"
    echo "=================================================="
    echo ""
    echo "Target Namespace: $NAMESPACE"
    echo "Release Name: $RELEASE_NAME"
    echo "Values File: $VALUES_FILE"
    echo ""
    
    check_prerequisites
    echo ""
    
    show_current_state
    
    if [[ -z "$DRY_RUN" ]]; then
        backup_current_state
        echo ""
    fi
    
    update_crds
    echo ""
    
    upgrade_operator
    echo ""
    
    if [[ -z "$DRY_RUN" ]]; then
        verify_upgrade
    fi
    
    echo ""
    echo_info "Upgrade process completed!"
    if [[ -z "$DRY_RUN" ]]; then
        echo_info "Backup saved to: $BACKUP_DIR"
    fi
}

main "$@"

