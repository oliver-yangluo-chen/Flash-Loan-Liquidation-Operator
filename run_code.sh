sudo docker container prune --force
sudo docker image rm defi-mooc-lab2
sudo docker build -t defi-mooc-lab2 .
sudo docker run -e ALCHE_API="6e9Zr49W_6pDiiz01b7YISCO_IQeCdKu" -it defi-mooc-lab2 npm test

