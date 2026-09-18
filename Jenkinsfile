pipeline {
    agent {
        label 'linux'
    }

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 10, unit: 'MINUTES')
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

                    whoami
                    test "$(id -u)" -ne 0

                    git --version
                    java -version
                    python3 --version
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
                    test ! -e jenkins/.env.agent

                    git diff --check
                '''
            }
        }

        stage('Validate Build Credential') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'model-build-key-dev',
                        variable: 'MODEL_BUILD_KEY'
                    )
                ]) {
                    sh '''
                        set +x

                        if [ -z "${MODEL_BUILD_KEY:-}" ]; then
                            echo "ERROR: credential was not bound."
                            exit 1
                        fi

                        key_length="$(printf %s "$MODEL_BUILD_KEY" | wc -c)"

                        if [ "$key_length" -lt 40 ]; then
                            echo "ERROR: credential does not meet the expected encoded-key length."
                            exit 1
                        fi

                        echo "PASS: credential is available inside the protected block."
                    '''
                }
            }
        }

        stage('Validate Credential Cleanup') {
            steps {
                sh '''
                    set -eu

                    if [ -n "${MODEL_BUILD_KEY:-}" ]; then
                        echo "ERROR: credential remained available outside its scope."
                        exit 1
                    fi

                    echo "PASS: credential is unavailable outside the protected block."
                '''
            }
        }
    }

    post {
        success {
            echo 'Secret-safe Jenkins pipeline completed successfully.'
        }

        failure {
            echo 'Pipeline failed. Review the failing stage and console output.'
        }
    }
}