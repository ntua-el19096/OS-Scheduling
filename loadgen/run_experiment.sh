#!/bin/bash
[ "$EUID" -ne 0 ] && exec sudo "$0" "$@"
set -e
rm -rf tmp

# Function to run test mode
test_setup() {
    echo "Running in test mode..."

    # Change to the correct directory first
    cd /shared/loadgen
    cp dataset/workload_dur.txt dataset/workload_dur_original.txt
    head -n 20 dataset/workload_dur.txt > dataset/workload_dur_temp.txt
    mv dataset/workload_dur_temp.txt dataset/workload_dur.txt

    # Setup exit handler to restore original file
    restore_workload() {
        echo "Restoring original workload file..."
        cd /shared/loadgen
        if [ -f dataset/workload_dur_original.txt ]; then
            mv dataset/workload_dur_original.txt dataset/workload_dur.txt
        fi
    }
    trap 'restore_workload' EXIT INT TERM ERR
}

# Parse arguments
FIFO_ARG=""
NO_LOG_ARG=""
CUSTOM_FILENAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --test)
            test_setup
            shift
            ;;
        --fifo)
            FIFO_ARG="--fifo"
            shift
            ;;
        --no_log)
            NO_LOG_ARG="--no_log"
            shift
            ;;
        *)
            # First positional argument is filename
            if [[ -z "$CUSTOM_FILENAME" ]]; then
                CUSTOM_FILENAME="$1"
            fi
            shift
            ;;
    esac
done

HOSTNAME="$(hostname)"
HOSTNAME="${HOSTNAME:2}"
DATE="$(date +%d-%m-%Y_%H:%M)"
DEFAULT_FILENAME="${HOSTNAME}_${DATE}"

# Use custom filename if provided, otherwise use default
FILENAME="${CUSTOM_FILENAME:-$DEFAULT_FILENAME}"

#Change open fd limit
ulimit -n 16384

#Sync the shared folder to the home directory (not doing so makes perf record lose samples)
echo -e "Syncing shared folder to home directory\n"
rsync -av --delete --exclude 'dataset/trace' --exclude '.git' /shared/loadgen ~/
cd ~/loadgen/runners

#Setup cpu isolation
../cpu_isolation/setup_cpu_isolation.sh --main_cpu 0
echo $$ > /sys/fs/cgroup/loadgen/orchestrator/cgroup.procs

#Run the ftrace experiment and perf experiment
./run_experiment_ftrace.sh $FILENAME $FIFO_ARG

./run_experiment_perf.sh $FILENAME $FIFO_ARG

#Cleanup cpu isolation
../cpu_isolation/cleanup_cpu_isolation.sh

#Sync the results back to the shared folder (only if not using --no_log)
if [[ -z "$NO_LOG_ARG" ]]; then
	echo -e "\nSyncing results back to shared folder"
	sudo rsync -av --no-owner --no-group ~/loadgen/log /shared/loadgen/
else
	echo -e "\nSkipping rsync back to shared folder due to --no_log flag. Syncing tmp folder"
fi

#For debug purposes get the tmp folder
sudo rsync -av --delete --no-owner --no-group ~/loadgen/runners/tmp /shared/loadgen


#FOR FIFO EXECUTION REMOVE KERNEL RT LIMITS
#or run a kernel with CONFIG_RT_GROUP_SCHED disabled
#sysctl -w kernel.sched_rt_runtime_us=-1