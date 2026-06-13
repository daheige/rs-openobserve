# openobserve notes
  Observability Construction Notes
# arch
见: [openobserve-arch.md](openobserve-arch.md)

# openobserve
https://openobserve.ai/downloads/
推荐k8s或docker部署
![openobserve.png](openobserve.png)

# 测试环境部署
```shell
# 创建命名空间
kubectl create ns openobserve

# 创建secret
export ZO_ROOT_USER_EMAIL=daheige313@gmail.com
export ZO_ROOT_USER_PASSWORD=root123456

# 这一步一般会提前创建好，或者使用nacos管理配置
kubectl create secret generic openobserve-auth \
    --namespace openobserve \
    --from-literal=email=${ZO_ROOT_USER_EMAIL} \
    --from-literal=password=${ZO_ROOT_USER_PASSWORD}

# 应用修改后的 YAML
kubectl apply -f k8s/deployment.yaml

# 验证openobserve运行状态
kubectl get pvc -n openobserve
kubectl get pod -n openobserve

# 本地转发5080端口
kubectl port-forward -n openobserve svc/openobserve 5080:5080
# 访问 http://localhost:5080

# 或者本地使用server nodeport模式转发
kubectl apply -f k8s/server-nodeport.yaml
#curl http://<<节点IP>:30080

# 根据实际情况部署ingress以及域名解析即可，这里省略
```

