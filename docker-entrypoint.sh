#!/bin/bash
set -e

echo "Starting dbus and avahi-daemon for mDNS..."
mkdir -p /var/run/dbus

# Disable the supervisor's Python-level mDNS — on Docker/Windows, the native
# windows-mdns.exe handles LAN mDNS.  Without this, the supervisor would
# advertise the container's internal 172.x IP, confusing Vector.
export DISABLE_SUPERVISOR_MDNS="true"
export WHISPER_MODEL="${WHISPER_MODEL:-base.en}"

# Remove old PID if restarting container
rm -f /run/dbus/pid
dbus-daemon --system
# avahi-daemon disabled — on Docker/Windows, windows-mdns.exe handles mDNS.
# avahi would broadcast the container's 172.x IP, confusing Vector.
# avahi-daemon -D

# Safely manage user data in the bind mount
mkdir -p /user-data/jdocs

# Provide the Windows mDNS reflector .exe on first run
# (pre-compiled during Docker build for Windows users)
if [ -f /root/vector-pod/windows-mdns.exe ] && [ ! -f /user-data/windows-mdns.exe ]; then
    cp /root/vector-pod/windows-mdns.exe /user-data/windows-mdns.exe
    echo "Exported windows-mdns.exe to /user-data/ (run it on Windows to bridge mDNS)"
fi


# Vector-AI persona
if [ ! -f /user-data/persona.txt ]; then
    cp /root/vector-pod/vector-ai/persona.txt /user-data/persona.txt
fi
rm -f /root/vector-pod/vector-ai/persona.txt
ln -s /user-data/persona.txt /root/vector-pod/vector-ai/persona.txt

# Wire-Pod botSdkInfo.json
if [ -f /root/vector-pod/wire-pod/chipper/jdocs/botSdkInfo.json ] && [ ! -f /user-data/jdocs/botSdkInfo.json ]; then
    cp /root/vector-pod/wire-pod/chipper/jdocs/botSdkInfo.json /user-data/jdocs/botSdkInfo.json
fi
rm -rf /root/vector-pod/wire-pod/chipper/jdocs
ln -s /user-data/jdocs /root/vector-pod/wire-pod/chipper/jdocs

# Import certs if provided
if [ -d /user-data/certs ]; then
    rm -rf /root/vector-pod/wire-pod/certs /root/vector-pod/wire-pod/chipper/certs
    ln -s /user-data/certs /root/vector-pod/wire-pod/certs
    ln -s /user-data/certs /root/vector-pod/wire-pod/chipper/certs
fi

# Import old session-certs if provided
if [ -d /user-data/session-certs ]; then
    rm -rf /root/vector-pod/wire-pod/chipper/session-certs
    ln -s /user-data/session-certs /root/vector-pod/wire-pod/chipper/session-certs
fi

# Import old botConfig.txt if provided
if [ -f /user-data/botConfig.txt ]; then
    rm -f /root/vector-pod/wire-pod/chipper/botConfig.txt
    ln -s /user-data/botConfig.txt /root/vector-pod/wire-pod/chipper/botConfig.txt
fi

# Persist apiConfig.json (Wire-Pod's main config with setup flags)
if [ ! -f /user-data/apiConfig.json ]; then
    if [ -f /root/vector-intelligence/shared/config/wirepod-apiConfig.json ]; then
        cp /root/vector-intelligence/shared/config/wirepod-apiConfig.json /user-data/apiConfig.json
    elif [ -f /root/vector-pod/wire-pod/chipper/apiConfig.json ]; then
        cp /root/vector-pod/wire-pod/chipper/apiConfig.json /user-data/apiConfig.json
    fi
fi
rm -f /root/vector-pod/wire-pod/chipper/apiConfig.json
ln -s /user-data/apiConfig.json /root/vector-pod/wire-pod/chipper/apiConfig.json

# Vector-AI memory db
if [ ! -f /user-data/memory.db ]; then
    touch /user-data/memory.db
fi
ln -sf /user-data/memory.db /root/vector-pod/vector-ai/memory.db

# Set default values if empty
OLLAMA_MAIN_MODEL=${OLLAMA_MAIN_MODEL:-"gemma3:12b"}
OLLAMA_SUMMARY_MODEL=${OLLAMA_SUMMARY_MODEL:-"llama3.2:3b"}


echo "Ensuring Ollama models ($OLLAMA_MAIN_MODEL, $OLLAMA_SUMMARY_MODEL) are downloaded..."
# Start Ollama temporarily to pull models
ollama serve > /dev/null 2>&1 &
OLLAMA_PID=$!

echo "Waiting for Ollama to start..."
until curl -s http://127.0.0.1:11434 > /dev/null; do
  sleep 1
done

echo "Pulling models..."
ollama pull "$OLLAMA_MAIN_MODEL"
ollama pull "$OLLAMA_SUMMARY_MODEL"

# Stop temporary Ollama process so supervisor can manage it
kill $OLLAMA_PID
wait $OLLAMA_PID 2>/dev/null || true

echo "Starting Vector Pod Supervisor..."
cd /root/vector-pod
exec /root/vector-pod/vector-ai/venv/bin/python supervisor.py
