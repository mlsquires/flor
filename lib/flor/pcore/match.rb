
class Flor::Pro::Match < Flor::Pro::Case

  name 'match'

  def pre_execute

    unatt_unkeyed_children

    conditional = true
    @node['val'] = payload['ret'] if non_att_children.size.even?
    found_val = @node.has_key?('val')
    t = tree
    changed = false

    t[1].each_with_index do |ct, i|

      next if ct[0] == '_att'
      next(found_val = true) unless found_val
      next(conditional = true) unless conditional

      conditional = false
      t[1][i] = patternize(ct)
      changed = changed || t[1][i] != ct
    end

    @node['tree'] = t if changed
  end

  def execute_child(index=0, sub=nil, h=nil)

    t = tree[1][index]

    if t && %w[ _pat_arr _pat_obj ].include?(t[0])
      payload['_pat_val'] = @node['val']
    end

    super
  end

  protected

  def patternize(t)

    t[0] = "_pat#{t[0]}" if %w[ _arr _obj ].include?(t[0])

    t[1].each_with_index { |ct, i|
      t[1][i] = patternize(t[1][i])
    } if t[1].is_a?(Array)

    t
  end

  def match?

    if b = payload.delete('_pat_binding')
      b
    else
      payload['ret'] == @node['val']
    end
  end

  def else?(ncid)

    t = tree[1][ncid]; return false unless t

    t[0, 2] == [ '_', [] ] ||
    t[0, 2] == [ 'else', [] ]
  end
end

