pipeline {
    agent {
        label 'linux && docker'
    }

    environment {
        APP_DIR = 'app/secure-model-api'
        IMAGE_REPOSITORY = 'secure-model-api'
        JFROG_REGISTRY = '127.0.0.1:8082'
        JFROG_DEV_REPOSITORY = 'secure-ai-dev-local'
    }

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate Agent') {
            steps {
                sh '''
                    set -eu

                    echo "Node: ${NODE_NAME}"
                    echo "Workspace: ${WORKSPACE}"

                    test "$(id -u)" -ne 0
                    test -S /var/run/docker.sock

                    git --version
                    python3 --version
                    docker --version
                    docker buildx version
                    docker compose version

                    docker info --format \
                      'Server={{.ServerVersion}} Driver={{.Driver}}'

                    echo "PASS: dedicated Docker agent is ready."
                '''
            }
        }

        stage('Validate Repository') {
            steps {
                sh '''
                    set -eu

                    test -f README.md
                    test -f .gitignore
                    test -f jenkins/compose.yaml
                    test -f jfrog/compose.yaml
                    test -f jfrog/.env.example
                    test -f "${APP_DIR}/Dockerfile"
                    test -f "${APP_DIR}/tests/test_crypto.py"

                    test ! -e jenkins/.env.agent
                    test ! -e jfrog/.env.jfrog

                    git diff --check

                    echo "PASS: repository structure is valid."
                '''
            }
        }

        stage('Prepare Build Metadata') {
            steps {
                script {
                    env.GIT_SHA_SHORT = sh(
                        script: 'git rev-parse --short=12 HEAD',
                        returnStdout: true
                    ).trim()

                    env.TEST_IMAGE_REF =
                        "${env.IMAGE_REPOSITORY}:test-${env.BUILD_NUMBER}"

                    env.IMAGE_REF =
                        "${env.IMAGE_REPOSITORY}:${env.GIT_SHA_SHORT}"

                    env.PUBLISHED_IMAGE_REF =
                        "${env.JFROG_REGISTRY}/" +
                        "${env.JFROG_DEV_REPOSITORY}/" +
                        "${env.IMAGE_REPOSITORY}:" +
                        "${env.GIT_SHA_SHORT}"

                    env.SMOKE_CONTAINER =
                        "secure-model-api-ci-${env.BUILD_NUMBER}"

                    env.MODEL_KEY_VOLUME =
                        "secure-model-api-key-${env.BUILD_NUMBER}"

                    currentBuild.displayName =
                        "#${env.BUILD_NUMBER} ${env.GIT_SHA_SHORT}"

                    currentBuild.description =
                        "Artifact: ${env.PUBLISHED_IMAGE_REF}"
                }

                sh '''
                    set -eu

                    echo "Commit: ${GIT_SHA_SHORT}"
                    echo "Local image: ${IMAGE_REF}"
                    echo "JFrog image: ${PUBLISHED_IMAGE_REF}"
                '''
            }
        }

        stage('Validate Credentials') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'model-build-key-dev',
                        variable: 'MODEL_BUILD_KEY'
                    ),
                    file(
                        credentialsId: 'model-source-dev',
                        variable: 'MODEL_SOURCE_FILE'
                    )
                ]) {
                    sh '''
                        set +x
                        set -eu

                        test -n "${MODEL_BUILD_KEY:-}"
                        test -s "${MODEL_SOURCE_FILE}"

                        python3 -c \
                          'import base64, os; key = base64.b64decode(os.environ["MODEL_BUILD_KEY"], validate=True); assert len(key) == 32'

                        echo "PASS: protected build inputs are valid."
                    '''
                }
            }
        }

        stage('Validate Credential Isolation') {
            steps {
                sh '''
                    set -eu

                    if [ -n "${MODEL_BUILD_KEY:-}" ]; then
                        echo "ERROR: Secret Text remained outside its scope."
                        exit 1
                    fi

                    if [ -n "${MODEL_SOURCE_FILE:-}" ]; then
                        echo "ERROR: Secret File remained outside its scope."
                        exit 1
                    fi

                    echo "PASS: build credentials are isolated."
                '''
            }
        }

        stage('Crypto Unit Tests') {
            steps {
                sh '''
                    set -eu

                    docker buildx build \
                      --load \
                      --target test \
                      --tag "${TEST_IMAGE_REF}" \
                      "${APP_DIR}"

                    docker run --rm \
                      --network none \
                      --read-only \
                      --cap-drop ALL \
                      --security-opt no-new-privileges:true \
                      --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
                      "${TEST_IMAGE_REF}"

                    echo "PASS: crypto unit tests completed."
                '''
            }
        }

        stage('Build Encrypted Image') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'model-build-key-dev',
                        variable: 'MODEL_BUILD_KEY'
                    ),
                    file(
                        credentialsId: 'model-source-dev',
                        variable: 'MODEL_SOURCE_FILE'
                    )
                ]) {
                    sh '''
                        set +x
                        set -eu

                        docker buildx build \
                          --load \
                          --no-cache-filter builder \
                          --secret id=model_key,env=MODEL_BUILD_KEY \
                          --secret "id=model_source,src=${MODEL_SOURCE_FILE}" \
                          --tag "${IMAGE_REF}" \
                          "${APP_DIR}"

                        echo "PASS: encrypted image built as ${IMAGE_REF}."
                    '''
                }
            }
        }

        stage('Image Hardening Gate') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'model-build-key-dev',
                        variable: 'MODEL_BUILD_KEY'
                    ),
                    file(
                        credentialsId: 'model-source-dev',
                        variable: 'MODEL_SOURCE_FILE'
                    )
                ]) {
                    sh '''
                        set +x
                        set -eu

                        image_user="$(
                            docker image inspect \
                              --format '{{.Config.User}}' \
                              "${IMAGE_REF}"
                        )"

                        if [ "${image_user}" != "10001:10001" ]; then
                            echo "ERROR: image does not use the expected non-root user."
                            exit 1
                        fi

                        healthcheck="$(
                            docker image inspect \
                              --format '{{json .Config.Healthcheck.Test}}' \
                              "${IMAGE_REF}"
                        )"

                        if [ "${healthcheck}" = "null" ] ||
                           [ -z "${healthcheck}" ]; then
                            echo "ERROR: image has no health check."
                            exit 1
                        fi

                        if docker image inspect "${IMAGE_REF}" |
                           grep -Fq -- "${MODEL_BUILD_KEY}"; then
                            echo "ERROR: build key appears in image configuration."
                            exit 1
                        fi

                        if docker history \
                             --no-trunc \
                             --format '{{.CreatedBy}}' \
                             "${IMAGE_REF}" |
                           grep -Fq -- "${MODEL_BUILD_KEY}"; then
                            echo "ERROR: build key appears in image history."
                            exit 1
                        fi

                        encrypted_copy="$(mktemp)"
                        inspection_container=""

                        cleanup_inspection() {
                            if [ -n "${inspection_container}" ]; then
                                docker rm -f \
                                  "${inspection_container}" \
                                  >/dev/null 2>&1 || true
                            fi

                            rm -f "${encrypted_copy}"
                        }

                        trap cleanup_inspection EXIT HUP INT TERM

                        inspection_container="$(
                            docker create "${IMAGE_REF}"
                        )"

                        docker cp \
                          "${inspection_container}:/app/models/model.enc" \
                          "${encrypted_copy}"

                        test -s "${encrypted_copy}"

                        if cmp -s \
                          "${MODEL_SOURCE_FILE}" \
                          "${encrypted_copy}"; then
                            echo "ERROR: model artifact was not encrypted."
                            exit 1
                        fi

                        docker run --rm \
                          --network none \
                          --read-only \
                          --cap-drop ALL \
                          --security-opt no-new-privileges:true \
                          --entrypoint /bin/sh \
                          "${IMAGE_REF}" \
                          -c '
                              test -s /app/models/model.enc
                              test ! -e /app/tests
                          '

                        echo "PASS: image hardening gate completed."
                    '''
                }
            }
        }

        stage('Runtime Smoke Test') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'model-build-key-dev',
                        variable: 'MODEL_BUILD_KEY'
                    )
                ]) {
                    sh '''
                        set +x
                        set -eu

                        docker volume create \
                          "${MODEL_KEY_VOLUME}" \
                          >/dev/null

                        printf %s "${MODEL_BUILD_KEY}" |
                          docker run --rm \
                            --interactive \
                            --network none \
                            --read-only \
                            --user 0:0 \
                            --entrypoint /bin/sh \
                            --mount \
                              "type=volume,source=${MODEL_KEY_VOLUME},target=/secret" \
                            "${IMAGE_REF}" \
                            -c '
                                umask 077
                                cat > /secret/model-key
                                chown 10001:10001 /secret/model-key
                                chmod 600 /secret/model-key
                            '

                        docker run --detach \
                          --name "${SMOKE_CONTAINER}" \
                          --label \
                            "secure-ai.ci.build=${BUILD_TAG}" \
                          --user 10001:10001 \
                          --read-only \
                          --cap-drop ALL \
                          --security-opt no-new-privileges:true \
                          --pids-limit 100 \
                          --memory 256m \
                          --cpus 1.0 \
                          --tmpfs \
                            /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
                          --tmpfs \
                            /dev/shm:rw,noexec,nosuid,nodev,size=16m,mode=0700,uid=10001,gid=10001 \
                          --mount \
                            "type=volume,source=${MODEL_KEY_VOLUME},target=/run/secrets,readonly" \
                          "${IMAGE_REF}" \
                          >/dev/null

                        runtime_status="starting"

                        for attempt in $(seq 1 30); do
                            runtime_status="$(
                                docker inspect \
                                  --format \
                                  '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
                                  "${SMOKE_CONTAINER}"
                            )"

                            if [ "${runtime_status}" = "healthy" ]; then
                                break
                            fi

                            if [ "${runtime_status}" = "unhealthy" ]; then
                                docker logs "${SMOKE_CONTAINER}"
                                exit 1
                            fi

                            sleep 2
                        done

                        if [ "${runtime_status}" != "healthy" ]; then
                            docker logs "${SMOKE_CONTAINER}"
                            echo "ERROR: service did not become healthy."
                            exit 1
                        fi

                        test "$(
                            docker exec \
                              "${SMOKE_CONTAINER}" \
                              id -u
                        )" = "10001"

                        test "$(
                            docker inspect \
                              --format '{{.HostConfig.ReadonlyRootfs}}' \
                              "${SMOKE_CONTAINER}"
                        )" = "true"

                        docker exec \
                          "${SMOKE_CONTAINER}" \
                          test -s /dev/shm/model.bin

                        docker exec \
                          "${SMOKE_CONTAINER}" \
                          python -c '
import urllib.request

for path in ("/health", "/ready"):
    with urllib.request.urlopen(
        "http://127.0.0.1:8000" + path,
        timeout=3
    ) as response:
        assert response.status == 200
        print(f"PASS: {path} returned HTTP {response.status}")
'

                        echo "PASS: hardened runtime smoke test completed."
                    '''
                }
            }
        }

        stage('Publish Development Artifact') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'jfrog-dev-registry',
                        usernameVariable: 'JFROG_USERNAME',
                        passwordVariable: 'JFROG_PASSWORD'
                    )
                ]) {
                    sh '''
                        set +x
                        set -eu

                        docker_config="$(mktemp -d)"

                        cleanup_publish() {
                            docker image rm -f \
                              "${PUBLISHED_IMAGE_REF}" \
                              >/dev/null 2>&1 || true

                            rm -rf "${docker_config}"
                        }

                        trap cleanup_publish EXIT HUP INT TERM

                        chmod 700 "${docker_config}"

                        auth_value="$(
                            printf '%s:%s' \
                              "${JFROG_USERNAME}" \
                              "${JFROG_PASSWORD}" |
                            base64 |
                            tr -d '\n'
                        )"

                        jq -n \
                          --arg registry "${JFROG_REGISTRY}" \
                          --arg auth "${auth_value}" \
                          '{auths: {($registry): {auth: $auth}}}' \
                          > "${docker_config}/config.json"

                        chmod 600 "${docker_config}/config.json"

                        docker image tag \
                          "${IMAGE_REF}" \
                          "${PUBLISHED_IMAGE_REF}"

                        if ! push_output="$(
                            DOCKER_CONFIG="${docker_config}" \
                              docker push \
                              "${PUBLISHED_IMAGE_REF}" \
                              2>&1
                        )"; then
                            printf '%s\n' "${push_output}"
                            echo "ERROR: JFrog image publication failed."
                            exit 1
                        fi

                        printf '%s\n' "${push_output}"

                        published_digest="$(
                            printf '%s\n' "${push_output}" |
                              awk '/digest: sha256:/ { print $3 }' |
                              tail -n 1
                        )"

                        if [ -z "${published_digest}" ]; then
                            echo "ERROR: registry did not return an image digest."
                            exit 1
                        fi

                        image_id="$(
                            docker image inspect \
                              --format '{{.Id}}' \
                              "${IMAGE_REF}"
                        )"

                        {
                            printf 'git_commit=%s\n' "${GIT_COMMIT}"
                            printf 'git_short_sha=%s\n' "${GIT_SHA_SHORT}"
                            printf 'jenkins_build=%s\n' "${BUILD_TAG}"
                            printf 'local_image=%s\n' "${IMAGE_REF}"
                            printf 'local_image_id=%s\n' "${image_id}"
                            printf 'published_image=%s\n' "${PUBLISHED_IMAGE_REF}"
                            printf 'published_digest=%s\n' "${published_digest}"
                        } > artifact-metadata.txt

                        echo "Local image: ${IMAGE_REF}"
                        echo "Local image ID: ${image_id}"
                        echo "Published image: ${PUBLISHED_IMAGE_REF}"
                        echo "Published digest: ${published_digest}"
                        echo "PASS: immutable development artifact published to JFrog."
                    '''
                }

                archiveArtifacts(
                    artifacts: 'artifact-metadata.txt',
                    fingerprint: true,
                    onlyIfSuccessful: true
                )
            }
        }

        stage('Validate Final Credential Isolation') {
            steps {
                sh '''
                    set -eu

                    test -z "${MODEL_BUILD_KEY:-}"
                    test -z "${MODEL_SOURCE_FILE:-}"
                    test -z "${JFROG_USERNAME:-}"
                    test -z "${JFROG_PASSWORD:-}"

                    echo "PASS: no Jenkins credential remains bound."
                '''
            }
        }
    }

    post {
        always {
            sh '''
                set +x
                set +e

                if [ -n "${SMOKE_CONTAINER:-}" ]; then
                    docker rm -f \
                      "${SMOKE_CONTAINER}" \
                      >/dev/null 2>&1 || true
                fi

                if [ -n "${MODEL_KEY_VOLUME:-}" ]; then
                    docker volume rm -f \
                      "${MODEL_KEY_VOLUME}" \
                      >/dev/null 2>&1 || true
                fi

                if [ -n "${TEST_IMAGE_REF:-}" ]; then
                    docker image rm -f \
                      "${TEST_IMAGE_REF}" \
                      >/dev/null 2>&1 || true
                fi

                echo "PASS: temporary CI resources removed."
            '''

            deleteDir()
        }

        success {
            echo "CI completed successfully: ${env.PUBLISHED_IMAGE_REF}"
        }

        failure {
            echo 'CI failed. Review the first failed stage and its console output.'
        }
    }
}