json.id node.node_id
json.connected node.connected
json.created_at node.created_at
json.updated_at node.updated_at
json.name node.name
json.os node.os
json.driver node.driver
json.kernel_version node.kernel_version
json.labels node.labels
json.mem_total node.mem_total
json.mem_limit node.mem_limit
json.cpus node.cpus
json.public_ip node.public_ip
json.node_number node.node_number
json.grid do
  json.partial!("app/views/v1/grids/grid", grid: node.grid) if node.grid
end
