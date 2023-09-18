#!/bin/bash

#SBATCH --nodes=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=0
#SBATCH --partition=standard
#SBATCH --time=04:00:00
#SBATCH --account=project_462000185
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err


module load cray-python
source ../venv/bin/activate

CHECKPOINT="/flash/project_462000319/megatron-33B-checkpoints/run_fixed_starcoder/global_step6192/"
OUTPUT="checkpoints/33B_step6192"
CONFIG="bloom_configs/33B.json"

python3 tools/convert_bloom_original_checkpoint_to_pytorch.py \
    --bloom_checkpoint_path $CHECKPOINT \
    --pytorch_dump_folder_path $OUTPUT \
    --bloom_config_file $CONFIG \
    --pretraining_tp 2
