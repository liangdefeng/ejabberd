# How to build

Enter the folder of the file, execute the command below.

docker build -t ejabberd-build-server .
docker run --rm -v $(pwd):$(pwd) -w $(pwd) ejabberd-build-server do deps.get, deps.compile, compile

Copy the files from _build\dev\lib\ to the server.

