#!/bin/bash

#SBATCH --exclude=nid006865,nid005613,nid005988
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=8
##SBATCH --cpus-per-task=8
#SBATCH --mem=0
#SBATCH --partition=standard-g
#SBATCH --time=0-00:30:00
#SBATCH --gpus-per-node=mi250:8
#SBATCH --exclusive=user
#SBATCH --hint=nomultithread
#SBATCH --account=project_462000273
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err

# if run without sbatch, invoke here
if [ -z $SLURM_JOB_ID ]; then
    mkdir -p logs
    sbatch "$0"
    exit
fi

# hold separate logs for easier debugging
rm -rf separate-logs
mkdir -p separate-logs

LEARNING_RATE=1.5e-4

set -euo pipefail

# symlink logs/latest.out and logs/latest.err
ln -f -s $SLURM_JOB_ID.out logs/latest.out
ln -f -s $SLURM_JOB_ID.err logs/latest.err

CHECKPOINT_PATH=checkpoints
TENSORBOARD_PATH=tensorboard
#rm -rf "$CHECKPOINT_PATH" "$TENSORBOARD_PATH" # Start from scratch

# Data
TRAIN_DATA_PATH="train-data.txt"
VALID_DATA_PATH="validation-data.txt"

PP_SIZE=4
TP_SIZE=2

MICRO_BATCH_SIZE=2
GLOBAL_BATCH_SIZE=1024

export WORLD_SIZE=$((SLURM_GPUS_ON_NODE*SLURM_JOB_NUM_NODES))

TRAIN_SAMPLES=146_500_000
TRAIN_SAMPLES=${TRAIN_SAMPLES//_}    # drop "_" for bash math
LR_DECAY_SAMPLES=$TRAIN_SAMPLES
LR_WARMUP_SAMPLES=$((TRAIN_SAMPLES/100))

NLAYERS=40
NHIDDEN=6144
NHEADS=48
SEQ_LEN=2048

SAVE_INTERVAL=1000
OPTIMIZER_ARGS=" \
    --optimizer adam \
    --adam-beta1 0.9 \
    --adam-beta2 0.95 \
    --adam-eps 1e-8 \
    --lr $LEARNING_RATE \
    --min-lr 2e-5 \
    --lr-decay-style cosine \
    --lr-decay-samples $LR_DECAY_SAMPLES \
    --lr-warmup-samples $LR_WARMUP_SAMPLES \
    --clip-grad 1.0 \
    --weight-decay 1e-1 \
    "

GPT_ARGS=" \
    --num-layers $NLAYERS \
    --hidden-size $NHIDDEN \
    --num-attention-heads $NHEADS \
    --attention-head-type multiquery \
    --seq-length $SEQ_LEN \
    --max-position-embeddings $SEQ_LEN \
    --micro-batch-size $MICRO_BATCH_SIZE \
    --global-batch-size $GLOBAL_BATCH_SIZE \
    --train-samples $TRAIN_SAMPLES \
    --tokenizer-type GPT2BPETokenizer \
    --vocab-file vocab_with_fim_tokens.json \
    --merge-file merges.txt \
    --init-method-std 0.0048 \
    --bf16 \
    --seed 42 \
    --attention-dropout 0.1 \
    --hidden-dropout 0.1 \
    --recompute-granularity full \
    --recompute-method uniform \
    --make-vocab-size-divisible-by 128 \
    $OPTIMIZER_ARGS \
    --no-gradient-accumulation-fusion \
    --valid-num-workers 0 \
    --num-workers 0 \
    "

#     --fim-rate 0.5 \

OUTPUT_ARGS=" \
    --log-interval 1 \
    --save-interval $SAVE_INTERVAL \
    --eval-interval 100 \
    --eval-iters 100 \
    --tensorboard-dir $TENSORBOARD_PATH \
    "

CMD=" \
    Megatron-LM/pretrain_gpt.py \
    --tensor-model-parallel-size $TP_SIZE \
    --pipeline-model-parallel-size $PP_SIZE \
    --sequence-parallel \
    $GPT_ARGS \
    $OUTPUT_ARGS \
    --save $CHECKPOINT_PATH \
    --load $CHECKPOINT_PATH \
    --train-weighted-split-paths-path $TRAIN_DATA_PATH \
    --valid-weighted-split-paths-path $VALID_DATA_PATH \
    "

# Bind masks from Samuel
c=fe

# Bind mask for one thread per core
BIND_MASK_1="0x${c}000000000000,0x${c}00000000000000,0x${c}0000,0x${c}000000,0x${c},0x${c}00,0x${c}00000000,0x${c}0000000000"

# Bind mask for two threads per core
BIND_MASK_2="0x${c}00000000000000${c}000000000000,0x${c}00000000000000${c}00000000000000,0x${c}00000000000000${c}0000,0x${c}00000000000000${c}000000,0x${c}00000000000000${c},0x${c}00000000000000${c}00,0x${c}00000000000000${c}00000000,0x${c}00000000000000${c}0000000000"

BIND_MASK="$BIND_MASK_1"
echo "Using --cpu-bind=mask_cpu:$BIND_MASK"

echo $CMD

echo "START $SLURM_JOBID: $(date)"

srun \
    --label \
    --cpu-bind=mask_cpu:$BIND_MASK \
    launch.sh \
    $CMD

echo "END $SLURM_JOBID: $(date)"
