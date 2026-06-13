#!/bin/bash

# 设置变量
export ZO_ROOT_USER_EMAIL="root@example.com"
export ZO_ROOT_USER_PASSWORD="Complexpass#123"
export NAMESPACE="openobserve"

# 创建命名空间（如果不存在）
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 创建 Secret
kubectl create secret generic openobserve-auth \
  --namespace ${NAMESPACE} \
  --from-literal=email="${ZO_ROOT_USER_EMAIL}" \
  --from-literal=password="${ZO_ROOT_USER_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 验证
kubectl get secret -n ${NAMESPACE} openobserve-auth -o jsonpath='{.data.email}' | base64 -d
kubectl get secret -n ${NAMESPACE} openobserve-auth -o jsonpath='{.data.password}' | base64 -d
