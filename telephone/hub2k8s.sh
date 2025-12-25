#!/usr/bin/env bash
set -euo pipefail

echo "🚀 GitHub Repository Deployment to Kubernetes"
echo "============================================"
echo

# ... [previous sections unchanged: repo clone, tag, namespace, .env parsing, SQL scan, Postgres generation] ...

############################################
# 🔍 Dockerfiles → Build Images & Generate Deployment/Service
############################################
echo "🔍 Scanning for Dockerfiles..."
mapfile -t DOCKERFILES < <(find "$ROOT_DIR" -type f \( -iname "Dockerfile" -o -iname "Dockerfile.*" \) 2>/dev/null || true)

if [[ ${#DOCKERFILES[@]} -eq 0 ]]; then
  echo "❌ No Dockerfiles found. Exiting."
  exit 1
fi

echo "🐳 Building Docker images with tag: $TAG"
echo

for FILE in "${DOCKERFILES[@]}"; do
  DIR_PATH="$(dirname "$FILE")"
  DIR_NAME="$(basename "$DIR_PATH")"

  # Critical fix: if Dockerfile in root → use repo name, never "root"
  if [[ "$DIR_PATH" == "$ROOT_DIR" ]]; then
  APP_NAME="$REPO_NAME"
  CONTAINER_NAME="$REPO_NAME"
else
  APP_NAME="$REPO_NAME"
  CONTAINER_NAME="$REPO_NAME"
fi

  IMAGE_NAME="${APP_NAME}:${TAG}"
  echo "🔨 Building: $IMAGE_NAME from $FILE"

  docker build -f "$FILE" -t "$IMAGE_NAME" "$DIR_PATH"

  if kind get clusters 2>/dev/null | grep -q "staging-cluster"; then
    kind load docker-image "$IMAGE_NAME" --name staging-cluster
  fi

  PORT=$(grep -i '^EXPOSE' "$FILE" | awk '{print $2}' | head -1 || echo "8000")
  [[ -z "$PORT" ]] && PORT=8000

  # Deployment filename: always repo-name-based, no "root"
  DEPLOYMENT_FILE="$K8S_OUT_DIR/${APP_NAME}-deployment.yaml"

  cat > "$DEPLOYMENT_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name:  $CONTAINER_NAME                 # ← Clean: e.g. frontend-super-admin
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
    spec:
      containers:
      - name: $DIR_NAME
        image: $IMAGE_NAME
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: $PORT
        envFrom:
        - configMapRef:
            name: ${REPO_NAME}-config
        - secretRef:
            name: ${REPO_NAME}-secret
EOF

  if [[ ! "$DIR_NAME" == *"cli"* ]]; then
    cat >> "$DEPLOYMENT_FILE" <<EOF
        readinessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 60
          periodSeconds: 20
EOF
  fi

  cat >> "$DEPLOYMENT_FILE" <<EOF

---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-service        # ← Clean: e.g. frontend-super-admin-service
  namespace: $NAMESPACE
spec:
  selector:
    app: $APP_NAME
  ports:
  - port: 80
    targetPort: $PORT
  type: NodePort
EOF

  echo "✅ Generated: $DEPLOYMENT_FILE"
done

echo
echo "🎉 All clean manifests generated (no '-root' anywhere!)"
echo "📂 Location: $K8S_OUT_DIR"
ls -1 "$K8S_OUT_DIR"/*.yaml


############################################
# 🚀 DEPLOYMENT
############################################
read -p "Do you want to deploy to Kubernetes now? (y/N): " DEPLOY_CHOICE
if [[ "$DEPLOY_CHOICE" =~ ^[Yy]$ ]]; then
  kubectl apply -f "$K8S_OUT_DIR/" --namespace="$NAMESPACE" --recursive
  echo "✅ Deployment complete!"
  kubectl get all,pvc,svc -n "$NAMESPACE"
else
  echo "📂 Manifests ready at: $K8S_OUT_DIR"
  echo "   Deploy later with: kubectl apply -f $K8S_OUT_DIR/ -n $NAMESPACE"
fi