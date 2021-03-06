
class Flor::Pro::Iterator < Flor::Procedure

  def pre_execute

    @node['vars'] ||= {}

    @node['args'] = [] # before iterating, arguments are collected

    @node['ocol'] = nil # original collection
    @node['fun'] = nil # function

    @node['col'] = nil # collection
    @node['idx'] = -1

    unatt_unkeyed_children
  end

  def receive_non_att

    if @node['args']
      receive_argument
    else
      receive_iteration
      iterate
    end
  end

  protected

  def receive_argument

    @node['args'] << payload['ret']

    if children[@ncid]
      execute_child(@ncid)
    else
      iterate
    end
  end

  def iterate

    prepare_iterations unless @node['ocol']

    return no_iterate unless @node['fun']

    @node['idx'] += 1
    @node['mtime'] = Flor.tstamp

    return end_iterator if iterator_over?

    apply_iteration
  end

  def function_mandatory?

    true
  end

  def prepare_iterations

    prepare_iterator

    @node['args']
      .each { |a|
        if Flor.is_func_tree?(a)
          @node['fun'] ||= a
        elsif a.is_a?(Array) || a.is_a?(Hash)
          @node['ocol'] ||= a
        end }

    @node['ocol'] ||= node_payload_ret
    ocol = @node['ocol']

    fail Flor::FlorError.new(
      "Function not given to #{heap.inspect}", self
    ) if function_mandatory? && ( ! @node['fun'])
    fail Flor::FlorError.new(
      "Collection not given to #{heap.inspect}", self
    ) unless ocol.is_a?(Array) || ocol.is_a?(Hash)

    @node['col'] = Flor.to_coll(@node['ocol']) if @node['fun']
    @node['args'] = nil
  end

  def prepare_iterator

    @node['res'] = []
  end

  def apply_iteration

    vars = determine_iteration_vars

    args = vars.values
    vars.each { |k, v| @node['vars'][k] = v }

    apply(@node['fun'], args, tree[2])
  end

  def determine_iteration_vars

    idx = @node['idx']
    elt = @node['col'][idx]
    len = @node['col'].length

    if @node['ocol'].is_a?(Array)
      { 'elt' => elt, 'idx' => idx, 'len' => len }
    else
      { 'key' => elt[0], 'val' => elt[1], 'idx' => idx, 'len' => len }
    end
  end

  def iterator_over?

    @node['idx'] == @node['col'].size
  end

  def end_iterator

    wrap_reply('ret' => iterator_result)
  end
end


class Flor::Macro::Iterator < Flor::Macro

  def rewrite_iterator_tree(procedure_name)

    atts = att_children

    l = tree[2]

    th = [ procedure_name, [], l, *tree[3] ]
    atts.each { |ac| th[1] << Flor.dup(ac) }

    if non_att_children.any?

      td = [ 'def', [], l ]
      td[1] << [ '_att', [ [ 'res', [], l ] ], l ] if procedure_name == 'reduce'
      td[1] << [ '_att', [ [ 'elt', [], l ] ], l ]
      non_att_children.each { |nac| td[1] << Flor.dup(nac) }

      th[1] << td
    end

    th
  end
end

