#!/bin/bash

# Check if the script is run as root (UID 0)
if [[ $UID -eq 0 ]]; then
    # Running as root: use the default kubectl command, assuming necessary environment/configs are set for root.
    KUBECTL_CMD="kubectl"
    echo "Running as root. Using standard 'kubectl'."
else
    # Running as non-root: explicitly specify the kubeconfig file.
    # We use $HOME for the home directory of the current user.
    KUBECTL_CMD="kubectl --kubeconfig $HOME/.kube/config"
    echo "Running as non-root. Using '${KUBECTL_CMD}'."
fi

# Resource to check for the critical bottleneck (Memory is typically the most critical)
RESOURCE="memory"
# The scaling factor for Ki to Mi (1024)
SCALE_FACTOR=1024

# --- Helper Functions (Using AWK for Division) ---

# Function to safely convert any unit (Ki/Mi/Raw Bytes) to MiB (Megabytes)
# $1: Value string from kubectl (e.g., "26874661376", "29700Mi", "38126949Ki")
convert_to_mib() {
    local val=$1
    local unit=$(echo "$val" | grep -oE '[a-zA-Z]+$')
    local num=$(echo "$val" | grep -oE '^[0-9]+')

    if [[ -z "$num" ]]; then
        echo 0
        return
    fi

    # Use awk to handle floating point conversion and rounding
    if [[ "$unit" == "Ki" ]]; then
        # Convert Ki to Mi: Ki / 1024
        echo "$num" | awk '{printf "%.0f", $1 / 1024}'
    elif [[ "$unit" == "Mi" ]]; then
        # Value is already Mi, just echo it
        echo "$num"
    else
        # Assume raw bytes if no unit is found, convert Bytes to Mi: Bytes / (1024 * 1024)
        # Note: We must be cautious with very large byte numbers in awk on some systems.
        echo "$num" | awk '{printf "%.0f", $1 / 1048576}'
    fi
}

# --- Data Collection and Calculation ---

# Get a list of all schedulable worker and server nodes
NODES=$($KUBECTL_CMD get nodes --no-headers -o custom-columns=NAME:.metadata.name)
NUM_NODES=$(echo "$NODES" | wc -l)

TOTAL_CAPACITY_MI=0
TOTAL_REQUESTS_MI=0
MAX_NODE_REQUESTS_MI=0
BUSIEST_NODE=""

echo "--- Kubernetes Cluster Capacity Analysis ---"
echo "Using command: ${KUBECTL_CMD}"
echo "Analyzing ${NUM_NODES} nodes. Critical Resource: ${RESOURCE^}."
echo "------------------------------------------------"

for NODE in $NODES; do
    # 1. Get Node Capacity (Allocatable)
    # Extracts the Allocatable memory value (e.g., "34000Mi" or "35000000Ki")
    CAPACITY_VAL=$($KUBECTL_CMD describe node "$NODE" | awk "/^Allocatable:/{flag=1; next} /${RESOURCE}/ && flag{print \$2; exit}" | grep -oE '^[0-9]+(Mi|Ki)?$')

    # Convert to MiB using the helper function
    CAPACITY_MI=$(convert_to_mib "$CAPACITY_VAL")

    # 2. Get Node Requests
    # Extracts the Requested memory value (e.g., "26874661376", "29700Mi")
    # This AWK command is now carefully structured to grab the *second* field for memory in the "Allocated resources" block
    REQUESTS_VAL=$($KUBECTL_CMD describe node "$NODE" | awk '/Allocated resources:/,/Events:/{if ($1 == "memory") print $2; if ($1 == "cpu") print $2}' | grep -oE '^[0-9]+(Mi|Ki)?$')

    # Convert to MiB using the helper function
    REQUESTS_MI=$(convert_to_mib "$REQUESTS_VAL")

    # Handle cases where request data is missing or failed conversion
    if [ -z "$CAPACITY_MI" ] || [ -z "$REQUESTS_MI" ]; then
        echo "Warning: Skipped $NODE due to missing data or conversion error." >&2
        continue
    fi

    # 3. Calculate Totals and Busiest Node (Bash Integer Math)
    TOTAL_CAPACITY_MI=$((TOTAL_CAPACITY_MI + CAPACITY_MI))
    TOTAL_REQUESTS_MI=$((TOTAL_REQUESTS_MI + REQUESTS_MI))

    if [ "$REQUESTS_MI" -gt "$MAX_NODE_REQUESTS_MI" ]; then
        MAX_NODE_REQUESTS_MI="$REQUESTS_MI"
        BUSIEST_NODE="$NODE"
    fi
done

# --- Final Calculations and Summary Output (Bash Integer Math) ---
FREE_CAPACITY_MI=$((TOTAL_CAPACITY_MI - TOTAL_REQUESTS_MI))
NET_CAPACITY_AFTER_DRAIN=$((FREE_CAPACITY_MI - MAX_NODE_REQUESTS_MI))

echo "------------------------------------------------"
echo "--- Cluster Totals (for ${RESOURCE^}) ---"
echo "Total Cluster Allocatable: $((TOTAL_CAPACITY_MI / 1024)) Gi"
echo "Total Cluster Requests:    $((TOTAL_REQUESTS_MI / 1024)) Gi"
echo "Total Cluster Free Capacity: $((FREE_CAPACITY_MI / 1024)) Gi"
echo "------------------------------------------------"
echo "--- Maintenance Prediction ---"

if [ "$NET_CAPACITY_AFTER_DRAIN" -ge 0 ]; then
    echo "✅ PREDICTION: SUCCESSFUL"
    echo "The cluster has enough guaranteed capacity (Memory) to absorb the busiest node's workload."
    echo "Remaining Free Capacity after draining busiest node: $((NET_CAPACITY_AFTER_DRAIN / 1024)) Gi"
else
    echo "🚨 PREDICTION: FAILURE RISK"
    echo "The cluster does NOT have enough guaranteed free capacity (Memory) to absorb the busiest node's workload."
    # Use integer math for the negative result and division
    CAPACITY_SHORTFALL=$((-NET_CAPACITY_AFTER_DRAIN))
    echo "Capacity Shortfall: $((CAPACITY_SHORTFALL / 1024)) Gi"
fi

echo "------------------------------------------------"
echo "HIGHEST RISK NODE (If drained): $BUSIEST_NODE"
echo "Load to be re-scheduled: $((MAX_NODE_REQUESTS_MI / 1024)) Gi"
echo ""