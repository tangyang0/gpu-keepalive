# maintain_machine — 机器保活工具

防止 K8s 工作区因 GPU 长时间空闲被回收。原理：定期检测 GPU 利用率，
只在"持续空闲接近回收阈值"时用 `gpu_burn` 制造一次短暂负载刷新利用率；
有真实任务在跑时绝不干预（只重置空闲计时）。

## 文件说明

| 文件 | 说明 |
|---|---|
| `gpu_keepalive.sh` | 保活主脚本（bash） |
| `gpu_burn` | CUDA 负载生成器（已编译），把利用率顶到 ~100% |
| `gpu_burn.cu` | 上述工具的源码，重新编译：`/usr/local/cuda/bin/nvcc -O2 -o gpu_burn gpu_burn.cu` |
| `gpu_keepalive.log` | 脚本内部运行日志 |
| `keepalive.log` | nohup 启动时的 stdout/stderr |

## 使用方法

```bash
# 启动（后台，退出登录不失效；输出统一进本目录日志，别重定向到其他项目目录）
cd /data/tangyang/data_annotation_pipeline
nohup bash ../maintain_machine/gpu_keepalive.sh >> /data/tangyang/maintain_machine/keepalive.log 2>&1 &

# 查看状态
ps aux | grep gpu_keepalive | grep -v grep

# 看日志（空闲计时 / burn 记录都在这里）
tail -f /data/tangyang/maintain_machine/gpu_keepalive.log

# 停止
pkill -f gpu_keepalive.sh
```

注意：重复启动前先 `pkill -f gpu_keepalive.sh` 杀掉旧进程，避免多份同时跑。

## 参数（环境变量覆盖，均可选）

| 变量 | 默认 | 含义 |
|---|---|---|
| `THRESHOLD` | 20 | 利用率 > 此值(%) 视为有真实任务，重置空闲计时 |
| `CHECK_INTERVAL` | 300 | 采样间隔（秒） |
| `IDLE_LIMIT` | 14400 | 连续空闲多久（秒）后烧一次，默认 4 小时 |
| `BURN_SECONDS` | 180 | 每次 burn 时长（秒） |
| `LOG` | 本目录 `gpu_keepalive.log` | 内部日志路径 |

示例：`IDLE_LIMIT=7200 nohup bash gpu_keepalive.sh >> keepalive.log 2>&1 &`
