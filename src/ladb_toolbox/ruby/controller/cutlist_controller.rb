require 'pathname'
require_relative 'controller'
require_relative '../model/size'
require_relative '../model/cutlist'
require_relative '../model/groupdef'
require_relative '../model/partdef'

class CutlistController < Controller

  def initialize(plugin)
    super(plugin, 'cutlist')
  end

  def setup_dialog_actions(dialog)

    # Setup toolbox dialog actions
    dialog.add_action_callback("ladb_cutlist_generate") do |action_context, json_params|

      params = JSON.parse(json_params)

      # Extract parameters
      length_increase = params['length_increase'].to_l
      width_increase = params['width_increase'].to_l
      thickness_increase = params['thickness_increase'].to_l
      std_thicknesses = _to_std_thicknesses_array(params['std_thicknesses'])
      part_number_letter = params['part_number_letter']
      part_number_sequence_by_group = params['part_number_sequence_by_group']

      # Generate cutlist
      data = generate_cutlist_data(
          length_increase,
          width_increase,
          thickness_increase,
          std_thicknesses,
          part_number_letter,
          part_number_sequence_by_group
      )

      # Callback to JS
      execute_js_callback('onCutlistGenerated', data)

    end

  end

  private

  def _fetch_leafs(entity, leaf_components)
    child_component_count = 0
    if entity.visible? and entity.layer.visible?
      if entity.is_a? Sketchup::Group
        entity.entities.each { |child_entity|
          child_component_count += _fetch_leafs(child_entity, leaf_components)
        }
      elsif entity.is_a? Sketchup::ComponentInstance
        entity.definition.entities.each { |child_entity|
          child_component_count += _fetch_leafs(child_entity, leaf_components)
        }
        bounds = entity.bounds
        if child_component_count == 0 and bounds.width > 0 and bounds.height > 0 and bounds.depth > 0
          leaf_components.push(entity)
          return 1
        end
      end
    end
    child_component_count
  end

  def _compute_faces_bounds(definition)
    bounds = Geom::BoundingBox.new
    definition.entities.each { |entity|
      if entity.is_a? Sketchup::Face
        bounds.add(entity.bounds)
      end
    }
    bounds
  end

  def _size_from_bounds(bounds)
    ordered = [bounds.width, bounds.height, bounds.depth].sort
    Size.new(ordered[2], ordered[1], ordered[0])
  end

  def _to_std_thicknesses_array(std_thicknesses_str)
    a = []
    std_thicknesses_str.split(';').each { |std_thickness|
      a.push((std_thickness + 'mm').to_l)
    }
    a
  end

  def _convert_to_std_thickness(thickness, std_thicknesses)
    std_thicknesses.each { |std_thickness|
      if thickness <= std_thickness
        return {
            :available => true,
            :value => std_thickness
        }
      end
    }
    {
        :available => false,
        :value => thickness
    }
  end

  public

  def generate_cutlist_data(length_increase, width_increase, thickness_increase, std_thicknesses, part_number_letter, part_number_sequence_by_group)

    # Retrieve selected entities or all if no selection
    model = Sketchup.active_model
    if model.selection.empty?
      entities = model.active_entities
      use_selection = false
    else
      entities = model.selection
      use_selection = true
    end

    # Fetch leaf components in given entities
    leaf_components = []
    entities.each { |entity|
      _fetch_leafs(entity, leaf_components)
    }

    status = Cutlist::STATUS_SUCCESS
    filename = Pathname.new(Sketchup.active_model.path).basename
    length_unit = Sketchup.active_model.options['UnitsOptions']['LengthUnit']

    # Create cut list
    cutlist = Cutlist.new(status, filename, length_unit)

    # Errors
    if leaf_components.length == 0
      if use_selection
        cutlist.add_error("Auncune instance de composant na été détectée dans votre sélection")
      else
        cutlist.add_error("Auncune instance de composant na été détectée sur votre scène")
      end
    end

    # Populate cutlist
    leaf_components.each { |component|

      material = component.material
      definition = component.definition

      material_name = material ? component.material.name : '[Matière non définie]'

      size = _size_from_bounds(_compute_faces_bounds(definition))
      std_thickness = _convert_to_std_thickness((size.thickness + thickness_increase).to_l, std_thicknesses)
      raw_size = Size.new(
          (size.length + length_increase).to_l,
          (size.width + width_increase).to_l,
          std_thickness[:value]
      )

      key = material_name + ':' + raw_size.thickness.to_s
      group_def = cutlist.get_group_def(key)
      unless group_def

        group_def = GroupDef.new
        group_def.material_name = material_name
        group_def.raw_thickness = raw_size.thickness
        group_def.raw_thickness_available = std_thickness[:available]

        cutlist.set_group_def(key, group_def)

      end

      part_def = group_def.get_part_def(definition.name)
      unless part_def

        part_def = PartDef.new
        part_def.name = definition.name
        part_def.raw_size = raw_size
        part_def.size = size

        group_def.set_part_def(definition.name, part_def)

      end
      part_def.count += 1
      part_def.add_component_guid(component.guid)

      group_def.part_count += 1

    }

    # Data
    # ----

    data = {
        :status => cutlist.status,
        :errors => cutlist.errors,
        :warnings => cutlist.warnings,
        :filepath => cutlist.filepath,
        :length_unit => cutlist.length_unit,
        :groups => []
    }

    # Sort and browse groups
    part_number = part_number_letter ? 'A' : '1'
    cutlist.group_defs.sort_by { |k, v| [v.raw_thickness] }.reverse.each { |key, group_def|

      if part_number_sequence_by_group
        part_number = part_number_letter ? 'A' : '1'    # Reset code increment on each group
      end

      group = {
          :id => group_def.id,
          :material_name => group_def.material_name,
          :part_count => group_def.part_count,
          :raw_thickness => group_def.raw_thickness,
          :raw_thickness_available => group_def.raw_thickness_available,
          :raw_area_m2 => 0,
          :raw_volume_m3 => 0,
          :parts => []
      }
      data[:groups].push(group)

      # Sort and browse parts
      group_def.part_defs.sort_by { |k, v| [v.size.thickness, v.size.length, v.size.width] }.reverse.each { |key, part_def|
        group[:raw_area_m2] += part_def.raw_size.area_m2
        group[:raw_volume_m3] += part_def.raw_size.volume_m3
        group[:parts].push({
                                :name => part_def.name,
                                :length => part_def.size.length,
                                :width => part_def.size.width,
                                :thickness => part_def.size.thickness,
                                :count => part_def.count,
                                :raw_length => part_def.raw_size.length,
                                :raw_width => part_def.raw_size.width,
                                :number => part_number,
                                :component_guids => part_def.component_guids
                            }
        )
        part_number = part_number.succ
      }

    }

    # Reorder groups by material_name ASC, raw_thickness DESC
    data[:groups].sort_by! { |v| [ v[:material_name], -v[:raw_thickness] ] }

    data
  end

end