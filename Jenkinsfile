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
    }

    post {
        success {
            echo 'Initial Jenkins pipeline completed successfully.'
        }

        failure {
            echo 'Pipeline failed. Review the failing stage and console output.'
        }
    }
}