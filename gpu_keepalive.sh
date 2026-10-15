#!/usr/bin/env bash
# 按需保活：定期检测 GPU 利用率，只有在“持续空闲”接近回收阈值时才制造一次负载。
# 若检测到真实任务正在跑（利用率高于阈值），则重置计时并且绝不插手。
# 依赖同目录下已编译的 gpu_burn（由 gpu_burn.cu 编译）。
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BURN_BIN="$DIR/gpu_burn"

THRESHOLD=${THRESHOLD:-20}               # 利用率 > 该值视为“GPU 正在工作”，会重置空闲计时
CHECK_INTERVAL=${CHECK_INTERVAL:-300}    # 每隔多少秒采样一次（默认 5 分钟）
IDLE_LIMIT=${IDLE_LIMIT:-14400}          # 连续空闲达到该秒数就烧一次（默认 4 小时，留足余量）
BURN_SECONDS=${BURN_SECONDS:-180}        # 每次制造负载的时长（秒）
LOG=${LOG:-$DIR/gpu_keepalive.log}

log() { echo "$(date -Is) $*" | tee -a "$LOG"; }

if [[ ! -x "$BURN_BIN" ]]; then
    log "找不到可执行的 gpu_burn，请先编译： /usr/local/cuda/bin/nvcc -O2 -o $BURN_BIN $DIR/gpu_burn.cu"
    exit 1
fi

# 取所有 GPU 中的最高利用率：只要有任意一张卡在忙，就认为 GPU 正在工作
gpu_util() {
    nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
        | awk 'BEGIN{m=0}{if(($1+0)>m)m=$1+0}END{print m+0}'
}

# GPU 数量（探测失败则退回 1，至少保住 0 号卡）
gpu_count() {
    local n
    n=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
    (( n > 0 )) && echo "$n" || echo 1
}

# 对每张卡各拉起一个 gpu_burn（靠 CUDA_VISIBLE_DEVICES 绑定），全部跑完才返回。
# gpu_burn 自身不调用 cudaSetDevice，只会用 device 0，因此必须逐卡起进程。
# 返回 0 表示全部成功，否则返回失败的卡数。
burn_all() {
    local secs=$1 n pids=() idx failed=0
    n=$(gpu_count)
    for (( idx = 0; idx < n; idx++ )); do
        CUDA_VISIBLE_DEVICES="$idx" "$BURN_BIN" "$secs" >>"$LOG" 2>&1 &
        pids+=($!)
    done
    for (( idx = 0; idx < ${#pids[@]}; idx++ )); do
        if ! wait "${pids[idx]}"; then
            log "  GPU ${idx} burn 失败"
            failed=$(( failed + 1 ))
        fi
    done
    return "$failed"
}

log "gpu_keepalive(按需) 启动：每 ${CHECK_INTERVAL}s 检测一次；连续空闲 ${IDLE_LIMIT}s 后烧 ${BURN_SECONDS}s；阈值 ${THRESHOLD}%"
trap 'log "gpu_keepalive 已停止"; exit 0' INT TERM

low_since=0
burn_count=0
while true; do
    util=$(gpu_util)
    now=$(date +%s)

    if (( util > THRESHOLD )); then
        # 有真实任务在跑：重置空闲计时，不做任何干预
        if (( low_since != 0 )); then
            log "检测到 GPU 正在工作（${util}%），重置空闲计时"
        fi
        low_since=0
    else
        (( low_since == 0 )) && low_since=$now
        elapsed=$(( now - low_since ))
        if (( elapsed >= IDLE_LIMIT )); then
            burn_count=$(( burn_count + 1 ))
            burn_start=$(date +%s)
            log "第 ${burn_count} 次 burn 开始 @ $(date -Is)（已连续空闲 $(( elapsed / 60 )) 分钟，当前 ${util}%，共 $(gpu_count) 张卡）"
            if burn_all "$BURN_SECONDS"; then
                dur=$(( $(date +%s) - burn_start ))
                log "第 ${burn_count} 次 burn 结束 @ $(date -Is)，实际耗时 ${dur}s，全部 GPU 利用率已刷新"
            else
                log "第 ${burn_count} 次 burn 部分失败（见上方日志）"
            fi
            low_since=0   # 已刷新利用率，空闲计时归零
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
