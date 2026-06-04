# The Crafting resource system reads this named output (configured via `output: output`
# in the sandbox YAML) and saves it as the resource state, available at
# /run/sandbox/fs/resources/macos/state in the workspace. The `cs mac` extension reads
# .public_ip straight from that file.
output "output" {
  value = {
    public_ip   = length(aws_instance.mac) > 0 ? aws_instance.mac[0].public_ip : null
    instance_id = length(aws_instance.mac) > 0 ? aws_instance.mac[0].id : null
    host_id     = aws_ec2_host.mac.id
  }
}
