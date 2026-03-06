#!/bin/bash

# ============================================================
# GSP313 - Implement Load Balancing on Compute Engine
# Challenge Lab - Full Solution Script
# ============================================================

set -e

ZONE="us-west1-a"
REGION="us-west1"

echo "============================================================"
echo " TASK 1: Create Web Server Instances"
echo "============================================================"

for i in 1 2 3; do
  echo "Creating web$i..."
  gcloud compute instances create web$i \
    --zone=$ZONE \
    --machine-type=e2-small \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags=network-lb-tag \
    --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo "<h3>Web Server: web'$i'</h3>" | tee /var/www/html/index.html'
done

echo "Creating firewall rule for HTTP traffic..."
gcloud compute firewall-rules create www-firewall-network-lb \
  --target-tags=network-lb-tag \
  --allow=tcp:80

echo "Waiting 60s for instances to initialize..."
sleep 60

echo "Verifying instances with curl..."
for i in 1 2 3; do
  IP=$(gcloud compute instances describe web$i --zone=$ZONE \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
  echo "web$i IP: $IP"
  curl -s --connect-timeout 5 http://$IP || echo "web$i not responding yet, try resetting if needed"
done

echo ""
echo "============================================================"
echo " TASK 2: Configure Network Load Balancing Service"
echo "============================================================"

echo "Reserving static external IP..."
gcloud compute addresses create network-lb-ip-1 \
  --region=$REGION

echo "Creating legacy HTTP health check..."
gcloud compute http-health-checks create basic-check

echo "Creating target pool..."
gcloud compute target-pools create www-pool \
  --region=$REGION \
  --http-health-check=basic-check

echo "Adding instances to target pool..."
gcloud compute target-pools add-instances www-pool \
  --instances=web1,web2,web3 \
  --instances-zone=$ZONE

echo "Creating forwarding rule..."
gcloud compute forwarding-rules create www-rule \
  --region=$REGION \
  --ports=80 \
  --address=network-lb-ip-1 \
  --target-pool=www-pool

NLB_IP=$(gcloud compute forwarding-rules describe www-rule \
  --region=$REGION --format='get(IPAddress)')
echo "Network LB IP: $NLB_IP"
echo "Test with: curl http://$NLB_IP"

echo ""
echo "============================================================"
echo " TASK 3: Create HTTP Load Balancer"
echo "============================================================"

echo "Creating instance template..."
gcloud compute instance-templates create lb-backend-template \
  --region=$REGION \
  --machine-type=e2-medium \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --tags=allow-health-check \
  --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo "<h3>Web Server: lb-backend</h3>" | tee /var/www/html/index.html'

echo "Creating managed instance group..."
gcloud compute instance-groups managed create lb-backend-group \
  --template=lb-backend-template \
  --size=2 \
  --zone=$ZONE

echo "Setting named port on MIG..."
gcloud compute instance-groups managed set-named-ports lb-backend-group \
  --named-ports=http:80 \
  --zone=$ZONE

echo "Creating firewall rule for health checks..."
gcloud compute firewall-rules create fw-allow-health-check \
  --network=default \
  --action=allow \
  --direction=ingress \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-check \
  --rules=tcp:80

echo "Reserving global external IP..."
gcloud compute addresses create lb-ipv4-1 \
  --ip-version=IPV4 \
  --global

echo "Creating HTTP health check..."
gcloud compute health-checks create http http-basic-check \
  --port=80

echo "Creating backend service..."
gcloud compute backend-services create web-backend-service \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=http-basic-check \
  --global

echo "Adding MIG to backend service..."
gcloud compute backend-services add-backend web-backend-service \
  --instance-group=lb-backend-group \
  --instance-group-zone=$ZONE \
  --global

echo "Creating URL map..."
gcloud compute url-maps create web-map-http \
  --default-service=web-backend-service

echo "Creating target HTTP proxy..."
gcloud compute target-http-proxies create http-lb-proxy \
  --url-map=web-map-http

echo "Creating global forwarding rule..."
gcloud compute forwarding-rules create http-content-rule \
  --address=lb-ipv4-1 \
  --global \
  --target-http-proxy=http-lb-proxy \
  --ports=80

HTTP_LB_IP=$(gcloud compute addresses describe lb-ipv4-1 \
  --format="get(address)" --global)

echo ""
echo "============================================================"
echo " ALL TASKS COMPLETE!"
echo "============================================================"
echo " Network LB IP : http://$NLB_IP"
echo " HTTP LB IP    : http://$HTTP_LB_IP"
echo " Note: HTTP LB may take 3-5 minutes to become available."
echo "============================================================"
