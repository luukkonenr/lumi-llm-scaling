#!/bin/bash

#SBATCH --nodes=128
#SBATCH --ntasks-per-node=8
#SBATCH --mem=0
#SBATCH --partition=standard-g
#SBATCH --time=2-00:00:00
#SBATCH --gpus-per-node=mi250:8
#SBATCH --exclusive=user
#SBATCH --hint=nomultithread
#SBATCH --account=project_462000319
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err

mkdir -p workdir
wd=$(realpath workdir)


# if run without sbatch, invoke here
if [ -z $SLURM_JOB_ID ]; then
    mkdir -p logs
    sbatch "$0"
    exit
fi

# debugging (noisy)
#export NCCL_DEBUG=INFO
#export RCCL_KERNEL_COLL_TRACE_ENABLE=1 
#export NCCL_DEBUG_SUBSYS=INIT,COLL
#export NCCL_DEBUG_SUBSYS=INIT

# distributed setup
export MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)
export MASTER_PORT=9999
export WORLD_SIZE=$SLURM_NTASKS

# compilers in the container
export CC=gcc-10
export CXX=g++-10

# singularity setup
CONTAINER="/scratch/project_462000319/rluukkon/singularity/pytorch-lumi_sles-rocm-5.5.1-python-3.10-pytorch-v2.0.1-apex-torchvision-torchdata-torchtext-torchaudio.sif"
SING_BIND="/scratch/project_462000319,/flash/project_462000319"

#export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/usr/local/lib"

# hold separate logs for easier debugging
rm -rf separate-logs
mkdir -p separate-logs

LEARNING_RATE=1.5e-4    # TODO probably too low

set -euo pipefail

# symlink logs/latest.out and logs/latest.err
ln -f -s $SLURM_JOB_ID.out logs/latest.out
ln -f -s $SLURM_JOB_ID.err logs/latest.err

CHECKPOINT_PATH=/flash/project_462000319/megatron-33B-checkpoints
TENSORBOARD_PATH="tensorboard/$SLURM_JOB_ID"
#rm -rf "$CHECKPOINT_PATH" "$TENSORBOARD_PATH" # Start from scratch

# Data
TRAIN_DATA_PATH="train-data.txt"
VALID_DATA_PATH="validation-data.txt"
TOKENIZER_PATH="/scratch/project_462000319/tokenizers/tokenizer_v6_fixed_fin/"

PP_SIZE=4
TP_SIZE=2

MICRO_BATCH_SIZE=1
GLOBAL_BATCH_SIZE=2048

# export MEMORY_OPT_ALLREDUCE_SIZE=2500000000
export MEMORY_OPT_ALLREDUCE_SIZE=1500000000
echo "MEMORY_OPT_ALLREDUCE_SIZE $MEMORY_OPT_ALLREDUCE_SIZE"
TRAIN_SAMPLES=488_281_250
TRAIN_SAMPLES=${TRAIN_SAMPLES//_}    # drop "_" for bash math
LR_DECAY_SAMPLES=$TRAIN_SAMPLES
LR_WARMUP_SAMPLES=$((TRAIN_SAMPLES/100))

NLAYERS=54
NHIDDEN=7168
NHEADS=56
FFN_HIDDEN_SIZE=$((4*NHIDDEN))
SEQ_LEN=2048


SAVE_INTERVAL=144
LOG_INTERVAL=10

EVAL_INTERVAL=600
EVAL_STEPS=100

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
    --ffn-hidden-size $FFN_HIDDEN_SIZE \
    --seq-length $SEQ_LEN \
    --max-position-embeddings $SEQ_LEN \
    --micro-batch-size $MICRO_BATCH_SIZE \
    --global-batch-size $GLOBAL_BATCH_SIZE \
    --train-samples $TRAIN_SAMPLES \
    --tokenizer-type PretrainedFromHF\
    --tokenizer-name-or-path $TOKENIZER_PATH \
    --init-method-std 0.0048 \
    --embed-layernorm \
    --sync-tp-duplicated-parameters \
    --bf16 \
    --seed 42 \
    --position-embedding-type alibi \
    --checkpoint-activations \
    --make-vocab-size-divisible-by 128 \
    $OPTIMIZER_ARGS \
    "

OUTPUT_ARGS=" \
    --log-interval $LOG_INTERVAL \
    --save-interval $SAVE_INTERVAL \
    --eval-interval $EVAL_INTERVAL \
    --eval-iters $EVAL_STEPS \
    --tensorboard-dir $TENSORBOARD_PATH \
    --tensorboard-queue-size 5 \
    --log-timers-to-tensorboard \
    --log-batch-size-to-tensorboard \
    --log-validation-ppl-to-tensorboard \
    "

ZERO_STAGE=0

mkdir -p ds_configs
DS_CONFIG_PATH="ds_configs/$SLURM_JOB_ID.json"

cat <<EOF > $DS_CONFIG_PATH
{
    "train_micro_batch_size_per_gpu": $MICRO_BATCH_SIZE,
    "train_batch_size": $GLOBAL_BATCH_SIZE,
    "gradient_clipping": 1.0,
    "zero_optimization": {
        "stage": $ZERO_STAGE
    },
    "bf16": {
        "enabled": true
    },
    "steps_per_print": 2000,
    "wall_clock_breakdown": false
}
EOF

DEEPSPEED_ARGS=" \
    --deepspeed \
    --deepspeed_config $DS_CONFIG_PATH \
    --zero-stage $ZERO_STAGE \
    "

CMD=" \
    pretrain_gpt.py \
    --tensor-model-parallel-size $TP_SIZE \
    --pipeline-model-parallel-size $PP_SIZE \
    $GPT_ARGS \
    $OUTPUT_ARGS \
    --save $CHECKPOINT_PATH \
    --load $CHECKPOINT_PATH \
    --train-weighted-split-paths-path $TRAIN_DATA_PATH \
    --valid-weighted-split-paths-path $VALID_DATA_PATH \
    --data-impl mmap \
    --dataloader-type single \
    --num-workers 2 \
     $DEEPSPEED_ARGS \
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

if [ ! -d $wd/cray-deps ] ; then
  rm -rf $wd/cray-deps
  mkdir $wd/cray-deps
  cp /usr/lib64/libcxi* $wd/cray-deps
fi

srun \
    --label \
    --cpu-bind=mask_cpu:$BIND_MASK \
    singularity exec \
    -B /opt/cray:/opt/cray \
    -B $wd/cray-deps:/opt/cray-deps \
    -B $wd:/workdir \
    -B "$SING_BIND" \
    "$CONTAINER" \
    ./launch.sh \
    $CMD

echo "END $SLURM_JOBID: $(date)"
