import Spacing

Garden := [].{
    plan = |width, depth, plants_per_square_metre| {
        area = width * depth
        { area_square_metres: area, plants: Spacing.plant_count(area, plants_per_square_metre) }
    }
}
