# The Crafting resource system reads this named output (configured via `output: output`
# in the sandbox YAML) and saves it as the resource state, available at
# /run/sandbox/fs/resources/macos/state in the workspace. The `cs mac` extension reads
# .public_ip straight from that file, and scripts/mac-prepare-volume.sh reads
# .data_volume_id to find the data volume on the Mac.
output "output" {
  value = {
    public_ip      = aws_instance.mac.public_ip
    instance_id    = aws_instance.mac.id
    host_id        = aws_ec2_host.mac.id
    data_volume_id = aws_ebs_volume.data.id
  }
}
