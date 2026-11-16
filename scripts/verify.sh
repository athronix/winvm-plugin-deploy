#!/usr/bin/env bash
# verify.sh · 直觉入口别名 → deploy-5-verify.sh（deploy 第 5 步，也是独立 verify 的唯一实现）
#
# 保留这个名字是因为"verify"是运维口语里最自然的动词；实现只有一份，避免双份判据漂移。
exec bash "$(dirname "${BASH_SOURCE[0]:-$0}")/deploy-5-verify.sh" "$@"
